# shellcheck shell=bash
# fail2ban: bans SSH brute-force sources through firewalld (sshd_config is not modified).

readonly FAIL2BAN_PACKAGES=(fail2ban-server fail2ban-firewalld python3-systemd)

fail2ban_setup() {
  if [[ $ENABLE_FAIL2BAN != "true" ]]; then
    log_info "Skipping fail2ban (ENABLE_FAIL2BAN=$ENABLE_FAIL2BAN)."
    return
  fi
  log_info "Installing fail2ban..."
  dnf -y install epel-release
  dnf -y install "${FAIL2BAN_PACKAGES[@]}"
  local rendered
  rendered=$(mktemp)
  # shellcheck disable=SC2016 # literal name for envsubst
  envsubst '${FAIL2BAN_IGNORE_IPS}' <"$REPO_DIR/templates/jail.local" >"$rendered"
  install_file "$rendered" /etc/fail2ban/jail.local || true
  rm -f "$rendered"
  systemctl enable fail2ban
  systemctl restart fail2ban
  fail2ban_unban_ignored
}

# fail2ban restores past bans from its database on restart, including addresses
# that have since been whitelisted: lift those explicitly.
fail2ban_unban_ignored() {
  [[ -n $FAIL2BAN_IGNORE_IPS ]] || return 0
  for _ in {1..10}; do
    fail2ban-client ping >/dev/null 2>&1 && break
    sleep 1
  done
  # shellcheck disable=SC2046 # word splitting of the banned list is intended
  python3 -I - "$FAIL2BAN_IGNORE_IPS" $(fail2ban-client get sshd banip) <<'EOF' | xargs -r fail2ban-client unban >/dev/null
import ipaddress
import sys

networks = [ipaddress.ip_network(entry, strict=False) for entry in sys.argv[1].split()]
for address in sys.argv[2:]:
    if any(ipaddress.ip_address(address) in network for network in networks):
        print(address)
EOF
}
