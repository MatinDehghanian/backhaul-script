# Backhaul Script

Interactive Bash installer and tunnel manager for Backhaul. Configure IRAN (server) and KHAREJ (client) tunnels, manage systemd services, view logs, and update the Backhaul executable.

## Requirements

- A Linux server with systemd and root access.
- Bash, curl, and jq. The script installs jq with apt-get if it is missing; this requires sudo to be available.
- OpenSSL for generating TLS certificates when needed.
- Access to raw.githubusercontent.com to download the script and executable.

The bundled `backhaul` executable targets Linux x86-64. Use a compatible server.

## Install and run

Run this command in a root Bash shell on each server:

```bash
bash <(curl -Ls --ipv4 https://raw.githubusercontent.com/MatinDehghanian/backhaul-script/refs/heads/main/backhaul.sh)
```

If you are logged in as a non-root user, enter a root shell first:

```bash
sudo -i
```

To save the script locally and run it:

```bash
curl -fLsS --ipv4 https://raw.githubusercontent.com/MatinDehghanian/backhaul-script/refs/heads/main/backhaul.sh -o backhaul.sh
chmod +x backhaul.sh
sudo ./backhaul.sh
```

On first run, the script downloads the executable directly from:

```text
https://raw.githubusercontent.com/MatinDehghanian/backhaul-script/refs/heads/main/backhaul
```

It applies `chmod +x` and installs the executable at `/root/backhaul-core/backhaul_premium`, the path used by its systemd services.

## Configure a tunnel

1. On the IRAN server, choose **1. Configure a new tunnel**, then **1) Configure IRAN (Server)**.
2. Follow the prompts for the bind address, transport, security settings, and port mappings.
3. On the KHAREJ server, run the same script and choose **1. Configure a new tunnel**, then **2) Configure KHAREJ (Client)**.
4. Enter the IRAN server address and port. Use matching transport and security settings on both sides.
5. Choose **3. Check tunnel status** to inspect the services.

The script offers these transports: `tcp`, `tcpmux`, `xtcpmux`, `ws`, `wss`, `wsmux`, `wssmux`, `xwsmux`, `anytls`, and `tun`.

## Manage and update

| Menu option | Action |
| --- | --- |
| 1. Configure a new tunnel | Create a server or client tunnel and its systemd service. |
| 2. Tunnel management | Inspect status, follow logs, restart, or delete a tunnel. |
| 3. Check tunnel status | Check configured tunnel services. |
| 4. Update Backhaul Core | Download the latest executable from this repository. Restart existing tunnel services afterward through tunnel management. |
| 5. Update script | Currently inactive. Rerun the install command to use the latest script. |
| 6. Remove Backhaul Core | Remove the core after deleting all tunnel services. |
| 0. Exit | Close the menu. |

## File locations

- Core and tunnel configurations: `/root/backhaul-core/`
- Server configurations: `/root/backhaul-core/iran<port>.toml`
- Client configurations: `/root/backhaul-core/kharej<port>.toml`
- TLS certificate files: `/root/backhaul-core/cert_files/`
- systemd services: `/etc/systemd/system/backhaul-iran<port>.service` and `/etc/systemd/system/backhaul-kharej<port>.service`

Rerun the install command whenever you want to open the menu again.
