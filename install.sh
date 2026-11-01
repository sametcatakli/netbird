#!/usr/bin/env bash
# Deploys a hardened, self-hosted NetBird server on AlmaLinux 9 or 10.
# Asks for missing settings on first run, then saves them to netbird.env.
# Safe to re-run: every step is idempotent and existing secrets are kept.
set -Eeuo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_DIR
readonly SETTINGS_FILE=$REPO_DIR/netbird.env

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
for module in settings system firewall docker fail2ban netbird; do
  # shellcheck source=/dev/null
  . "$REPO_DIR/lib/$module.sh"
done

trap 'log_error "Failed at line $LINENO: $BASH_COMMAND"' ERR

usage() {
  cat <<EOF
Usage: sudo ./install.sh

Settings are read from the environment, then from $SETTINGS_FILE.
Anything missing is asked interactively and saved to that file.
See netbird.env.example for every available setting.
EOF
}

print_proxy_instructions() {
  cat <<EOF

Configure the reverse proxy ($EXTERNAL_PROXY_IP) for https://$NETBIRD_DOMAIN:
  - Proxy "/" to http://$NETBIRD_HOST_IP:80 with WebSocket support.
  - Enable HTTP/2 on the HTTPS listener (required for gRPC).
  - Add the locations from $INSTALL_DIR/upstream-nginx.conf
    (Nginx Proxy Manager: "Advanced" tab of the proxy host).
EOF
}

print_summary() {
  if [[ $EDGE_PROXY == "external" ]]; then
    print_proxy_instructions
  fi
  echo
  echo "NetBird is running."
  echo "  Dashboard:    https://$NETBIRD_DOMAIN"
  if netbird_setup_required; then
    echo "  First admin:  https://$NETBIRD_DOMAIN/setup (create it now: the page is open until an admin exists)"
  fi
  echo "  Data:         $INSTALL_DIR (back up secrets.env: it encrypts the database)"
  echo "  Backup:       $REPO_DIR/scripts/backup.sh"
  echo
}

main() {
  if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    return
  fi
  require_root
  require_almalinux
  settings_load
  system_setup
  firewall_setup
  docker_setup
  fail2ban_setup
  netbird_setup
  print_summary
}

main "$@"
