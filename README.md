# NetBird on AlmaLinux

Hardened, self-hosted [NetBird](https://netbird.io) server on AlmaLinux 9 or 10 with Docker Compose:
management, signal, relay, STUN, embedded identity provider and dashboard on a single host.

## Quick start

On a fresh AlmaLinux 9 or 10 host (x86_64 or aarch64):

```bash
sudo dnf -y install git && git clone https://github.com/sametcatakli/netbird.git && cd netbird && sudo ./install.sh
```

The installer asks for the domain name, the deployment mode and the SSH protection settings,
saves the answers to `netbird.env`, then installs everything. When it finishes, open
`https://<domain>/setup` right away to create the first administrator.

## Deployment modes

**Direct.** The host faces the internet and gets its own Let's Encrypt certificate.

```
client ──443/tcp──► Traefik (TLS) ──► dashboard / netbird-server
client ──3478/udp─► netbird-server (STUN)
```

Forward `80/tcp`, `443/tcp` and `3478/udp` to the host.

**Behind a reverse proxy.** An existing proxy (Nginx Proxy Manager, nginx, ...) terminates TLS
and forwards plain HTTP to the host.

```
client ──443/tcp──► reverse proxy (TLS) ──80/tcp──► Traefik ──► dashboard / netbird-server
client ──3478/udp─────────────────────────────────► netbird-server (STUN)
```

Forward `3478/udp` to the host; HTTPS stays on the proxy. Port 80 of the host only accepts the
proxy's address (HTTP 403 for anyone else), and only that address is trusted for
`X-Forwarded-For`, so NetBird and the rate limiter see the real client IPs.

The proxy must:

- send `/` to `http://<host>:80` with WebSocket upgrade headers;
- serve HTTPS with HTTP/2 enabled, which gRPC requires;
- pass the gRPC paths with `grpc_pass` and keep long-lived connections open. The installer
  generates these locations in `/opt/netbird/upstream-nginx.conf`.

With Nginx Proxy Manager: create a proxy host to `http://<host>:80`, turn on *Websockets Support*,
then *Force SSL* and *HTTP/2 Support* in the SSL tab, and paste `upstream-nginx.conf` into the
*Advanced* tab.

## Configuration

The installer reads settings from the environment first, then from `netbird.env`, and asks for
anything still missing. Without a terminal it fails instead of asking. For an unattended install,
copy `netbird.env.example` to `netbird.env` and fill it in, or pass the values as environment
variables:

```bash
sudo NETBIRD_DOMAIN=vpn.example.com EDGE_PROXY=builtin ACME_EMAIL=ops@example.com \
  ENABLE_FAIL2BAN=true ./install.sh
```

| Setting | Description |
|---|---|
| `NETBIRD_DOMAIN` | Public domain name. Any name works. |
| `EDGE_PROXY` | `builtin` (direct) or `external` (behind a reverse proxy). |
| `ACME_EMAIL` | `builtin` only: Let's Encrypt contact address. |
| `EXTERNAL_PROXY_IP` | `external` only: IPv4 of the reverse proxy, as seen from the host. |
| `ENABLE_FAIL2BAN` | `true` to ban SSH brute-force sources. |
| `FAIL2BAN_IGNORE_IPS` | IPv4 addresses or CIDRs that are never banned. Put your admin network here. |
| `INSTALL_DIR` | Stack location, `/opt/netbird` by default. |
| `*_IMAGE` | Image overrides. The pinned defaults live in `lib/settings.sh`. |

To change a setting, edit `netbird.env` and run `sudo ./install.sh` again. The installer is
idempotent: it keeps the existing secrets and recreates the containers only when the rendered
configuration changed.

## Security

| Area | Measures |
|---|---|
| Updates | Full upgrade at install. Daily security updates with `dnf-automatic`, rebooting only when an update requires it. Docker and NetBird packages publish no security advisories, so a second daily run installs all their updates. Container images stay pinned and are upgraded on purpose (see Operations). |
| SELinux | Enforcing. Docker runs with SELinux labels (`selinux-enabled`, `:Z` mounts). |
| Firewall | firewalld allows SSH, `80/tcp`, `3478/udp`, and `443/tcp` in direct mode. Cockpit is closed. Docker-published ports bypass firewalld zones, so source filtering behind a proxy is enforced in Traefik. |
| Kernel | sysctl: no ICMP redirects or source routing, reverse-path filtering, SYN cookies, restricted kernel pointers, dmesg, BPF and ptrace, protected links. |
| Audit | auditd rules on Docker, the install directory, identity files, sudoers and `sshd_config`. |
| SSH | fail2ban: 5 failures in 10 minutes ban the source for 1 hour, longer on repeat. Whitelisted addresses are never banned and are unbanned on every run. `sshd_config` is never modified, so password login keeps working. |
| Docker daemon | `no-new-privileges`, no inter-container traffic on the default bridge, no userland proxy, live restore, log rotation. |
| Containers | Pinned images, all capabilities dropped (`NET_BIND_SERVICE` added back where needed), `no-new-privileges`, read-only root filesystem for Traefik and the server, rootless dashboard. The Docker socket is not mounted in any container. |
| TLS (direct mode) | Let's Encrypt, TLS 1.2+ with AEAD ciphers only, strict SNI, HTTP redirected to HTTPS. |
| HTTP | HSTS, `nosniff`, `X-Frame-Options: DENY`, referrer and permissions policies, per-client rate limit on the API and login endpoints. |
| Secrets | Generated once into `/opt/netbird/secrets.env`. It and every rendered file are `0600`, root only. |

## Operations

```bash
cd /opt/netbird
docker compose ps                       # status
docker compose logs -f netbird-server   # logs
```

**Backup.** `sudo ./scripts/backup.sh [directory]` stops the server for a few seconds and writes
the database, configuration and secrets to `/opt/netbird/backups` by default. Copy the archives
off the host. Keep `secrets.env` safe: it holds the database encryption key.

**Restore.** Stop the stack, extract `_data/` into the `netbird_netbird_data` volume and the
install directory back to `/opt/netbird`, then run `docker compose up -d`.

**Upgrade.** Read the NetBird release notes and take a backup, then:

```bash
git pull && sudo ./install.sh
```

## Clients and routing peer

Connect a client:

```bash
netbird up --management-url https://<domain>
```

To reach a local network through NetBird, create a setup key in the dashboard and enroll a host
on that network as a routing peer. The NetBird server itself can be that host. Then add the
network under *Networks* with this peer as its router.

```bash
sudo ./scripts/routing-peer.sh   # asks for the setup key
```

The script installs the official client package. Behind a reverse proxy, it also points the
domain at the proxy in `/etc/hosts`, because hosts on the local network usually cannot reach
their own public address (no hairpin NAT).

## Repository layout

```
install.sh               Entry point
netbird.env.example      Settings reference
lib/                     One module per step: settings, system, firewall, docker, fail2ban, netbird
config/                  Host files installed as-is: sysctl, auditd, Docker daemon, dnf-automatic
templates/               Stack and service configuration, rendered into /opt/netbird
scripts/backup.sh        Consistent backup
scripts/routing-peer.sh  Enrolls the host as a NetBird peer
```

## Notes

- If SELinux was disabled before the install, the next boot relabels the filesystem. Reboot once.
- The NetBird reverse-proxy and CrowdSec add-ons from the upstream installer are not included.

## License

[MIT](LICENSE)
