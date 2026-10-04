"""Exercise the real embedded socket helper on loopback; needs Bash 4+ and Python 3.

Runs a full 60-second echo soak. No Backhaul process, service or external host is used.
"""
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest


class ConnectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = os.environ.get("TEST_BASH", "bash")
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.client = cls.root / "iran"
        cls.server = cls.root / "kharej"
        cls.client.mkdir()
        cls.server.mkdir()
        source = (Path(__file__).resolve().parents[1] / "backhaul.sh").read_text()
        start = source.index("connection_tool() {")
        end = source.index("\npair_fingerprint()", start)
        cls.wrapper = cls.root / "tool.sh"
        cls.wrapper.write_text(
            'colorize() { printf "%s\\n" "$2"; }\n'
            + source[start:end]
            + '\nconfig_dir="$1"; shift; connection_tool "$@"\n'
        )
        cls.secret = "a" * 64

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_tool(self, side, action, *args):
        return subprocess.run(
            [self.bash, str(self.wrapper), str(side), action, *map(str, args)],
            capture_output=True, text=True, timeout=90,
        )

    def start_responder(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        proc = subprocess.Popen(
            [self.bash, str(self.wrapper), str(self.server), "responder", "127.0.0.1", str(port), self.secret],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True,
        )
        self.addCleanup(self.stop, proc)
        ready, _, _ = select.select([proc.stdout], [], [], 5)
        self.assertTrue(ready, "responder did not start within five seconds")
        line = proc.stdout.readline()
        self.assertIn("Ready on", line)
        return proc, port

    @staticmethod
    def stop(proc):
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=5)
        if proc.stdout:
            proc.stdout.close()

    @staticmethod
    def receive(sock, count):
        result = bytearray()
        while len(result) < count:
            chunk = sock.recv(count - len(result))
            if not chunk:
                raise ConnectionError("unexpected EOF")
            result.extend(chunk)
        return bytes(result)

    def test_01_occupied_backend_refused(self):
        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            result = self.run_tool(self.server, "responder", "127.0.0.1", occupied.getsockname()[1], self.secret)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not start", result.stderr)

    def test_02_lock_rejects_overlap_and_cancel_releases_it(self):
        proc, port = self.start_responder()
        blocked = self.run_tool(self.server, "route", "127.0.0.1", port)
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn("Another connection test", blocked.stdout)
        os.killpg(proc.pid, signal.SIGINT)
        output, _ = proc.communicate(timeout=5)
        self.assertIn("cancelled", output)
        self.assertEqual(proc.returncode, 130)
        # After cancellation the lock and listener can both be used again.
        proc2, _ = self.start_responder()
        self.stop(proc2)

    def test_03_wrong_nonce_is_not_success(self):
        _, port = self.start_responder()
        result = self.run_tool(self.client, "traffic", "127.0.0.1", port, "b" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL after 0/60", result.stdout)

    def test_04_proxy_headers_are_supported(self):
        for proxy in (b"PROXY TCP4 192.0.2.1 192.0.2.2 12345 443\r\n",
                      b"\r\n\r\n\0\r\nQUIT\n" + b"\x21\x11\x00\x0c" + b"\0" * 12):
            proc, port = self.start_responder()
            with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
                hello = b"BACKHAUL-TEST-1 " + self.secret.encode() + b"\n"
                sock.sendall(proxy + hello)
                self.assertEqual(self.receive(sock, len(hello)), hello)
                sock.sendall(struct.pack("!I", 5) + b"hello")
                self.assertEqual(self.receive(sock, 5), b"hello")
                sock.sendall(struct.pack("!I", 0))
            proc.wait(timeout=5)
            self.assertEqual(proc.returncode, 0)

    def test_05_full_soak_verifies_bytes_and_bulk_rate(self):
        proc, port = self.start_responder()
        started = time.monotonic()
        result = self.run_tool(self.client, "traffic", "127.0.0.1", port, self.secret)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreaterEqual(time.monotonic() - started, 59)
        self.assertIn("60/60 exact echoes and 1 MiB", result.stdout)
        self.assertIn("Combined upload+download echo rate", result.stdout)
        self.assertEqual(result.stdout.count("Echo "), 60)
        proc.wait(timeout=5)
        self.assertEqual(proc.returncode, 0)

    def test_06_route_is_labeled_as_reachability(self):
        _, port = self.start_responder()
        result = self.run_tool(self.client, "route", "127.0.0.1", port)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TCP connection success: 10/10", result.stdout)
        self.assertIn("not authentication, packet loss or tunnel throughput", result.stdout)
        self.assertEqual(result.stdout.count("Probe "), 10)

    def test_07_midstream_drop_reports_verified_count(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(5)
            port = listener.getsockname()[1]

            def drop_after_three():
                client, _ = listener.accept()
                with client:
                    client.settimeout(5)
                    hello = b"BACKHAUL-TEST-1 " + self.secret.encode() + b"\n"
                    self.assertEqual(self.receive(client, len(hello)), hello)
                    client.sendall(hello)
                    for _ in range(3):
                        size = struct.unpack("!I", self.receive(client, 4))[0]
                        client.sendall(self.receive(client, size))

            worker = threading.Thread(target=drop_after_three)
            worker.start()
            result = self.run_tool(self.client, "traffic", "127.0.0.1", port, self.secret)
            worker.join(timeout=5)
            self.assertFalse(worker.is_alive())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL after 3/60 verified echoes", result.stdout)
        self.assertNotIn("Combined upload+download echo rate", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
