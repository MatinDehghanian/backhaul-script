"""Verify embedded transport comparison with loopback relays and simulated services.

No Linux Backhaul binary, systemd service, firewall or TUN device is touched.
Python 3.11+ is used to independently parse every generated TOML configuration.
"""
import contextlib
import errno
import importlib.util
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import tempfile
import threading
import time
import tomllib
import unittest
from unittest import mock


def load_helper():
    source = (Path(__file__).resolve().parents[1] / 'backhaul.sh').read_text()
    start = source.index("<<'PY_COMPARE'\n") + len("<<'PY_COMPARE'\n")
    end = source.index('\nPY_COMPARE\n', start)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader('comparison', loader=None))
    exec(compile(source[start:end], 'backhaul.sh:PY_COMPARE', 'exec'), module.__dict__)
    return module


class Relay:
    def __init__(self, helper, entry, backend):
        self.helper, self.backend = helper, backend
        self.sock = helper.listener('127.0.0.1', entry)
        self.closed = threading.Event()
        self.clients = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.closed.is_set():
            try:
                client, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.clients.append(client)
            threading.Thread(target=self.forward, args=(client,), daemon=True).start()

    def forward(self, client):
        try:
            with client, socket.create_connection(('127.0.0.1', self.backend), timeout=3) as target:
                self.clients.append(target)
                def copy(source, destination):
                    try:
                        while data := source.recv(65536):
                            destination.sendall(data)
                    except OSError:
                        pass
                    with contextlib.suppress(OSError):
                        destination.shutdown(socket.SHUT_WR)
                thread = threading.Thread(target=copy, args=(client, target), daemon=True)
                thread.start()
                copy(target, client)
                thread.join(timeout=2)
        except OSError:
            pass

    def close(self):
        self.closed.set()
        self.sock.close()
        for client in self.clients:
            with contextlib.suppress(OSError):
                client.shutdown(socket.SHUT_RDWR)
        self.thread.join(timeout=2)


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.temp = tempfile.TemporaryDirectory(prefix='backhaul-comparison-test-')
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.link = {'v': 1, 'host': '127.0.0.1', 'coord': 54000, 'port': 54001, 'health': 55000,
                     'secret': 'a' * 64, 'block': '198.18.10.0/30', 'mode': 'quick', 'until': int(time.time()) + 3600}
        self.helper.PLANS = {'quick': (2, .01), 'stability': (60, 1)}
        self.helper.CONNECT_WAIT = .35
        self.helper.JOIN_WAIT = 5
        self.helper.ACK_WAIT = 5

    def test_link_validation_and_authenticated_messages(self):
        self.assertEqual(self.helper.decode_link(self.helper.encode_link(self.link)), self.link)
        for field, value in [('port', 0), ('coord', True), ('secret', 'weak'), ('block', '10.0.0.0/30'),
                             ('until', int(time.time()) - 1), ('host', 'host\n$(command)'), ('mode', 'bad')]:
            with self.assertRaises((ValueError, TypeError)):
                self.helper.validate_link(self.link | {field: value})
        with self.assertRaises(ValueError):
            self.helper.validate_link(self.link | {'extra': 'ignored'})
        message = self.helper.signed(self.link['secret'], {'action': 'poll'})
        self.assertEqual(self.helper.verified(self.link['secret'], message), {'action': 'poll'})
        message['payload']['action'] = 'cancel'
        with self.assertRaises(ValueError):
            self.helper.verified(self.link['secret'], message)

    def test_all_sixteen_configs_pair_without_global_tuning_or_iptables(self):
        self.assertEqual(len(self.helper.CASES), 16)
        net = {'local': '192.0.2.1', 'peer': '192.0.2.2', 'interface': 'eth0'}
        for case in self.helper.CASES:
            iran = tomllib.loads(self.helper.render_config('iran', case, self.link, 56000, 56001, 'bhcttest', net, '/tmp/cert', '/tmp/key'))
            kharej = tomllib.loads(self.helper.render_config('kharej', case, self.link, 56000, 56001, 'bhcttest2',
                                                          net | {'local': net['peer'], 'peer': net['local']}, '', ''))
            self.assertEqual(iran['security'], kharej['security'], case)
            self.assertFalse(iran['tuning']['auto_tuning'], case)
            self.assertFalse(kharej['tuning']['auto_tuning'], case)
            self.assertEqual(iran['ports']['mapping'], ['56000=56001'])
            self.assertNotIn('ports', kharej)
            if case.startswith('tun/'):
                self.assertEqual(iran['tun']['local_addr'], kharej['tun']['remote_addr'])
                self.assertEqual(iran['tun']['remote_addr'], kharej['tun']['local_addr'])
                self.assertEqual(iran['tun']['health_port'], self.link['health'])
                self.assertNotEqual(iran['tun']['health_port'], 56001)
                self.assertEqual(iran['ports']['forwarder'], 'backhaul')
            if '/ipx/' in case:
                self.assertNotIn('listener', iran)
                self.assertNotIn('dialer', kharej)
                self.assertEqual(iran['ipx']['mode'], 'server')
                self.assertEqual(kharej['ipx']['mode'], 'client')
                self.assertEqual(iran['ipx']['listen_ip'], kharej['ipx']['dst_ip'])
            if case.endswith('mux'):
                self.assertEqual(iran['mux'], kharej['mux'])

    def test_overlapping_tun_subnets_do_not_prevent_stream_tests(self):
        with mock.patch.object(self.helper, 'tun_problem', return_value='temporary TUN subnet overlaps a local route'):
            block = self.helper.pick_block()
        self.assertTrue(self.helper.ipaddress.ip_network(block).subnet_of(self.helper.ipaddress.ip_network('198.18.0.0/15')))

    def test_occupied_port_is_refused_before_services_are_paused(self):
        with self.helper.listener('0.0.0.0', 0) as occupied, self.helper.listener('127.0.0.1', 0) as spare:
            port = occupied.getsockname()[1]
            coord = spare.getsockname()[1]
            spare.close()
            with mock.patch.object(self.helper, 'PausedServices') as pause, mock.patch.object(self.helper, 'emit') as output:
                with self.assertRaises(OSError) as failure:
                    self.helper.server(str(self.root), '127.0.0.1', coord, port, 'quick')
                self.assertEqual(failure.exception.errno, errno.EADDRINUSE)
                pause.assert_not_called()
                output.assert_not_called()
            with self.helper.listener('127.0.0.1', coord):
                pass

    def test_services_restore_only_previously_running_units_even_when_stop_fails(self):
        calls = []
        def command(args):
            calls.append(args)
            if args[1] == 'list-units':
                return subprocess.CompletedProcess(args, 0, 'backhaul-iran8443.service loaded active running\n'
                                                  'backhaul-kharej9443.service loaded active running\n'
                                                  'unrelated.service loaded active running\n', '')
            return subprocess.CompletedProcess(args, int(args[1:3] == ['stop', 'backhaul-kharej9443.service']), '', '')
        paused = self.helper.PausedServices('/tmp/core')
        with mock.patch.object(self.helper, 'run_command', command), mock.patch.object(self.helper, 'emit'):
            with self.assertRaises(ValueError):
                with paused:
                    self.fail('failed stop must prevent starting a test engine')
        self.assertEqual([c[-1] for c in calls if c[1] == 'start'], ['backhaul-iran8443.service', 'backhaul-kharej9443.service'])
        self.assertEqual(paused.units, [])

    def test_failed_service_restore_is_reported_as_failure(self):
        paused = self.helper.PausedServices('/tmp/core')
        paused.units = ['backhaul-iran8443.service']
        with mock.patch.object(self.helper, 'run_command', return_value=subprocess.CompletedProcess([], 1, '', '')), \
             mock.patch.object(self.helper, 'emit') as output:
            with self.assertRaises(ValueError):
                paused.__exit__(None)
        self.assertIn('RESTORE FAILED', output.call_args[0][0])
        self.assertIn('systemctl start backhaul-iran8443.service', output.call_args[0][0])

    def test_stale_acknowledgements_cannot_advance_next_transport(self):
        sock = self.helper.listener('127.0.0.1', 0)
        coordinator = self.helper.Coordinator(self.link, sock, 56000)
        self.addCleanup(coordinator.close)
        client = 'b' * 32
        coordinator.client_id = client
        def request(action, index):
            return {'nonce': os.urandom(16).hex(), 'time': int(time.time()), 'client': client, 'action': action, 'index': index}
        coordinator.publish(phase='start', index=1)
        coordinator.handle(request('started', 1), '127.0.0.1', '127.0.0.1')
        self.assertTrue(coordinator.started.is_set())
        coordinator.publish(phase='stop')
        ack = request('stopped', 1)
        coordinator.handle(ack, '127.0.0.1', '127.0.0.1')
        self.assertTrue(coordinator.stopped.is_set())
        with self.assertRaises(ValueError):
            coordinator.handle(ack, '127.0.0.1', '127.0.0.1')
        coordinator.publish(phase='start', index=2)
        coordinator.handle(request('stopped', 1), '127.0.0.1', '127.0.0.1')
        self.assertFalse(coordinator.started.is_set())
        self.assertFalse(coordinator.stopped.is_set())
        coordinator.publish(phase='stop')
        coordinator.handle(request('stopped', 1), '127.0.0.1', '127.0.0.1')
        self.assertFalse(coordinator.stopped.is_set())
        coordinator.handle(request('stopped', 2), '127.0.0.1', '127.0.0.1')
        self.assertTrue(coordinator.stopped.is_set())

    def test_corrupt_upload_is_unstable_and_has_no_speed_result(self):
        helper = self.helper
        secret = helper.derived(self.link['secret'], 'echo')
        failures = []
        with helper.listener('127.0.0.1', 0) as sock:
            port = sock.getsockname()[1]
            def corrupt_backend():
                try:
                    conn, _ = sock.accept()
                    with conn:
                        conn.settimeout(5)
                        hello = b'BACKHAUL-COMPARE-1 ' + secret.encode() + b'\n'
                        self.assertEqual(helper.exact(conn, len(hello)), hello)
                        conn.sendall(hello)
                        for _ in range(2):
                            self.assertEqual(helper.exact(conn, 5), b'E\x00\x00\x00\x40')
                            conn.sendall(helper.exact(conn, 64))
                        self.assertEqual(helper.exact(conn, 5), b'U' + helper.struct.pack('!I', helper.BULK))
                        helper.exact(conn, helper.BULK)
                        conn.sendall(b'\0' * 32)
                except BaseException as exc:
                    failures.append(exc)
            worker = threading.Thread(target=corrupt_backend)
            worker.start()
            row = helper.measure('tcp', port, self.link, mock.Mock())
            worker.join(timeout=5)
            self.assertFalse(worker.is_alive())
        self.assertFalse(failures, failures)
        self.assertEqual(row['status'], 'UNSTABLE')
        self.assertEqual(row['ok'], 2)
        self.assertGreater(row['ping'], 0)
        self.assertNotIn('upload', row)
        self.assertNotIn('download', row)
        self.assertIn('verification failed', row['detail'])

    def test_engine_refuses_overlap_and_stops_actual_child(self):
        binary = self.root / 'fake-core'
        binary.write_text('#!/usr/bin/env python3\nimport time\ntime.sleep(60)\n')
        binary.chmod(0o755)
        engine = self.helper.Engine(str(binary), self.root, 'bhcttest')
        self.addCleanup(engine.stop)
        engine.start('[transport]\ntype="tcp"\n', False)
        process = engine.process
        self.assertEqual((self.root / 'test.toml').stat().st_mode & 0o777, 0o600)
        with self.assertRaises(ValueError):
            engine.start('[transport]\ntype="ws"\n', False)
        engine.stop()
        self.assertIsNotNone(process.poll())
        self.assertIsNone(engine.process)
        self.assertIsNone(engine.log)

    def exercise_pair(self, cancel=False):
        helper = self.helper
        iran, kharej = self.root / 'iran', self.root / 'kharej'
        iran.mkdir()
        kharej.mkdir()
        messages, errors, history = queue.Queue(), [], []
        active, restored = {'iran': 0, 'kharej': 0}, []
        state_mutex = threading.Lock()
        def emit(message):
            messages.put(message)
        class FakePause:
            def __init__(self, binary): self.side = Path(binary).parent.name
            def __enter__(self): return self
            def other_cores(self): return False
            def __exit__(self, *_): restored.append(self.side)
        class FakeEngine:
            def __init__(self, binary, directory, interface):
                self.side = Path(binary).parent.name
                self.interface = interface
                self.process = self.relay = None
            def start(self, config, tun):
                parsed = tomllib.loads(config)
                case = parsed['transport']['type']
                with state_mutex:
                    if active[self.side]: raise AssertionError('overlapping cores on ' + self.side)
                    if self.side == 'iran' and active['kharej']: raise AssertionError('previous KHAREJ core was not stopped')
                    active[self.side] += 1
                    history.append((self.side, 'start', case))
                self.process = object()
                if case == 'xtcpmux' and self.side == 'kharej':
                    raise ValueError('simulated client startup failure')
                if self.side == 'iran' and case != 'ws':
                    entry, backend = map(int, parsed['ports']['mapping'][0].split('='))
                    self.relay = Relay(helper, entry, backend)
            def check(self): pass
            def stop(self):
                if self.relay:
                    self.relay.close()
                    self.relay = None
                if self.process:
                    with state_mutex:
                        active[self.side] -= 1
                        history.append((self.side, 'stop', ''))
                    self.process = None
        def cancelled_measure(*_):
            raise KeyboardInterrupt
        with socket.socket() as probe1, socket.socket() as probe2:
            probe1.bind(('127.0.0.1', 0)); probe2.bind(('127.0.0.1', 0))
            coord, port = probe1.getsockname()[1], probe2.getsockname()[1]
        def start_server():
            try:
                helper.server(str(iran), '127.0.0.1', coord, port, 'quick')
            except BaseException as exc:
                errors.append(exc)
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(helper, 'Engine', FakeEngine))
            stack.enter_context(mock.patch.object(helper, 'PausedServices', FakePause))
            stack.enter_context(mock.patch.object(helper, 'tun_problem', return_value='TUN not available in this simulated loopback test'))
            stack.enter_context(mock.patch.object(helper, 'network_info', return_value={'local': '127.0.0.1', 'peer': '127.0.0.1', 'interface': 'lo', 'ipx_error': ''}))
            stack.enter_context(mock.patch.object(helper, 'emit', emit))
            if cancel:
                stack.enter_context(mock.patch.object(helper, 'measure', cancelled_measure))
            worker = threading.Thread(target=start_server)
            worker.start()
            announcement = messages.get(timeout=5)
            self.assertIn(helper.SCHEME, announcement)
            link = announcement.split('\n')[1]
            try:
                if cancel:
                    with self.assertRaises((OSError, ValueError)):
                        helper.client(str(kharej), link)
                else:
                    helper.client(str(kharej), link)
            finally:
                worker.join(timeout=10)
            self.assertFalse(worker.is_alive(), 'server did not finish cleaning up')
        self.assertEqual(active, {'iran': 0, 'kharej': 0})
        self.assertCountEqual(restored, ['iran', 'kharej'])
        self.assertEqual(list(iran.glob('.transport-compare-*')), [])
        self.assertEqual(list(kharej.glob('.transport-compare-*')), [])
        with helper.listener('127.0.0.1', coord), helper.listener('127.0.0.1', port):
            pass
        if cancel:
            self.assertTrue(any(isinstance(exc, KeyboardInterrupt) for exc in errors), errors)
        else:
            self.assertFalse(errors, errors)
            left = json.loads((iran / 'transport-test-results.json').read_text())
            right = json.loads((kharej / 'transport-test-results.json').read_text())
            self.assertEqual(left['results'], right['results'])
            self.assertEqual(len(left['results']), 16)
            by_case = {row['transport']: row for row in left['results']}
            self.assertEqual(by_case['ws']['status'], 'DOWN')
            self.assertEqual(by_case['xtcpmux']['status'], 'ERROR')
            self.assertEqual(by_case['tcp']['status'], 'AVAILABLE')
            self.assertGreater(by_case['tcp']['ping'], 0)
            self.assertGreater(by_case['tcp']['upload'], 0)
            self.assertGreater(by_case['tcp']['download'], 0)
            self.assertEqual(by_case['tcp']['ok'], 2)
            self.assertTrue(all(by_case[case]['status'] == 'SKIPPED' for case in helper.CASES if case.startswith('tun/')))
            self.assertEqual((iran / 'transport-test-results.json').stat().st_mode & 0o777, 0o600)
        return history

    def test_paired_run_is_sequential_with_real_verified_ping_and_speed(self):
        history = self.exercise_pair()
        self.assertEqual(sum(side == 'iran' and op == 'start' for side, op, _ in history), 9)

    def test_cancel_restores_both_sides_and_releases_ports(self):
        self.exercise_pair(cancel=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
