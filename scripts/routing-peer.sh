#!/usr/bin/env bash
# Enrolls this host as a NetBird peer, typically a routing peer for the local network.
# Usage: routing-peer.sh [setup-key]   (asked interactively when omitted)
set -Eeuo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_DIR
readonly NETBIRD_RPM_REPO=/etc/yum.repos.d/netbird.repo

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"

require_root
if [[ -f $REPO_DIR/netbird.env ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$REPO_DIR/netbird.env"
  set +a
fi
: "${NETBIRD_DOMAIN:?Run install.sh first, or set NETBIRD_DOMAIN.}"

SETUP_KEY=${1:-}
if [[ -z $SETUP_KEY ]]; then
  read -r -s -p "Setup key (Dashboard > Setup Keys): " SETUP_KEY </dev/tty
  echo
fi
[[ -n $SETUP_KEY ]] || die "A setup key is required."
readonly SETUP_KEY

install_client() {
  if rpm -q netbird >/dev/null 2>&1; then
    return
  fi
  log_info "Installing the NetBird client..."
  cat >"$NETBIRD_RPM_REPO" <<'EOF'
[netbird]
name=netbird
baseurl=https://pkgs.netbird.io/yum/
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=https://pkgs.netbird.io/yum/repodata/repomd.xml.key
EOF
  dnf -y install netbird
}

# Behind an upstream proxy on the LAN, the public name usually cannot hairpin
# back from this host, so pin it to the proxy.
pin_management_address() {
  [[ ${EDGE_PROXY:-builtin} == "external" ]] || return 0
  sed -i "/[[:space:]]$NETBIRD_DOMAIN\$/d" /etc/hosts
  printf '%s %s\n' "$EXTERNAL_PROXY_IP" "$NETBIRD_DOMAIN" >>/etc/hosts
}

enroll() {
  log_info "Enrolling this host with https://$NETBIRD_DOMAIN ..."
  netbird service install 2>/dev/null || true
  netbird service start 2>/dev/null || true
  # Passed through the environment so the key never shows up in the process list.
  NB_SETUP_KEY=$SETUP_KEY netbird up --management-url "https://$NETBIRD_DOMAIN"
  netbird status
}

install_client
pin_management_address
enroll
