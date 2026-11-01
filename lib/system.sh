# shellcheck shell=bash
# Base system: packages, automatic security updates, SELinux, kernel and audit hardening.

readonly BASE_PACKAGES=(
  audit chrony curl dnf-automatic gettext jq openssl
  policycoreutils-python-utils firewalld tar
)

system_install_packages() {
  log_info "Updating the system and installing base packages..."
  dnf -y upgrade --refresh
  dnf -y install "${BASE_PACKAGES[@]}"
  systemctl enable --now chronyd auditd
}

# Security updates for the whole system, with a reboot when one requires it
# (kernel, glibc...), plus all updates for the Docker and NetBird packages.
system_enable_automatic_updates() {
  log_info "Enabling automatic updates..."
  sed -i \
    -e 's/^upgrade_type\s*=.*/upgrade_type = security/' \
    -e 's/^apply_updates\s*=.*/apply_updates = yes/' \
    -e 's/^reboot\s*=.*/reboot = when-needed/' \
    /etc/dnf/automatic.conf
  install_file "$REPO_DIR/config/dnf/automatic-stack.conf" /etc/dnf/automatic-stack.conf || true
  local unit
  for unit in dnf-automatic-stack.service dnf-automatic-stack.timer; do
    install_file "$REPO_DIR/config/systemd/$unit" "/etc/systemd/system/$unit" || true
  done
  systemctl daemon-reload
  systemctl enable --now dnf-automatic.timer dnf-automatic-stack.timer
}

system_enforce_selinux() {
  log_info "Enforcing SELinux..."
  sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
  case $(getenforce) in
    Enforcing) ;;
    Permissive) setenforce 1 ;;
    Disabled)
      # Switching from disabled requires a full relabel at boot.
      touch /.autorelabel
      log_warn "SELinux was disabled: it will be enforcing after the next reboot (relabel scheduled)."
      ;;
  esac
}

system_harden_kernel() {
  log_info "Applying kernel hardening (sysctl)..."
  if install_file "$REPO_DIR/config/sysctl/99-netbird-hardening.conf" \
      /etc/sysctl.d/99-netbird-hardening.conf; then
    sysctl --system >/dev/null
  fi
}

system_install_audit_rules() {
  log_info "Installing audit rules..."
  if install_file "$REPO_DIR/config/audit/netbird.rules" \
      /etc/audit/rules.d/netbird.rules 0600; then
    augenrules --load >/dev/null
  fi
}

system_setup() {
  system_install_packages
  system_enable_automatic_updates
  system_enforce_selinux
  system_harden_kernel
  system_install_audit_rules
}
