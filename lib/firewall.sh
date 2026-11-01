# shellcheck shell=bash
# Host firewall: only SSH and the NetBird public ports are reachable.

readonly FIREWALL_ZONE=public
readonly FIREWALL_PORTS=(80/tcp 3478/udp)
# Only the builtin edge mode terminates TLS on this host.
readonly FIREWALL_TLS_PORT=443/tcp
readonly FIREWALL_REMOVED_SERVICES=(cockpit)

firewall_setup() {
  log_info "Configuring firewalld..."
  systemctl enable --now firewalld

  local service port
  for service in "${FIREWALL_REMOVED_SERVICES[@]}"; do
    firewall-cmd --permanent --zone="$FIREWALL_ZONE" --remove-service="$service" >/dev/null
  done
  firewall-cmd --permanent --zone="$FIREWALL_ZONE" --add-service=ssh >/dev/null
  for port in "${FIREWALL_PORTS[@]}"; do
    firewall-cmd --permanent --zone="$FIREWALL_ZONE" --add-port="$port" >/dev/null
  done
  local tls_action=--remove-port
  [[ $EDGE_PROXY == "builtin" ]] && tls_action=--add-port
  firewall-cmd --permanent --zone="$FIREWALL_ZONE" "$tls_action=$FIREWALL_TLS_PORT" >/dev/null
  firewall-cmd --reload >/dev/null
  systemctl disable --now cockpit.socket 2>/dev/null || true
}
