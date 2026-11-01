# shellcheck shell=bash
# Installer settings: precedence is environment > netbird.env > interactive prompt > default.

readonly DEFAULT_NETBIRD_SERVER_IMAGE=netbirdio/netbird-server:0.82.0
readonly DEFAULT_DASHBOARD_IMAGE=netbirdio/dashboard:v2.96.0-rootless
readonly DEFAULT_TRAEFIK_IMAGE=traefik:v3.7.15

is_fqdn()  { [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }
is_email() { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
is_ipv4() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local octet
  for octet in "${BASH_REMATCH[@]:1}"; do
    ((octet <= 255)) || return 1
  done
}
# IPv4 address or CIDR, space separated; an empty list is valid.
is_ipv4_list() {
  local entry
  for entry in $1; do
    is_ipv4 "${entry%/*}" || return 1
    if [[ $entry == */* ]]; then
      [[ ${entry#*/} =~ ^[0-9]+$ ]] && ((${entry#*/} <= 32)) || return 1
    fi
  done
}
is_boolean() { [[ $1 == "true" || $1 == "false" ]]; }
is_edge_mode() { [[ $1 == "builtin" || $1 == "external" ]]; }

has_tty() { { : </dev/tty; } 2>/dev/null; }

# prompt <variable> <question> <validator> [default]
# Asks until the answer passes the validator; an empty answer takes the default.
prompt() {
  local variable=$1 question=$2 validator=$3 default=${4:-} answer
  while true; do
    if [[ -n $default ]]; then
      read -r -p "$question [$default]: " answer </dev/tty
      answer=${answer:-$default}
    else
      read -r -p "$question: " answer </dev/tty
    fi
    if "$validator" "$answer"; then
      printf -v "$variable" '%s' "$answer"
      return
    fi
    log_warn "Invalid value '$answer'."
  done
}

prompt_yes_no() {
  local question=$1 default=$2 answer
  while true; do
    read -r -p "$question [$([[ $default == "true" ]] && echo Y/n || echo y/N)]: " answer </dev/tty
    case ${answer,,} in
      "") [[ $default == "true" ]]; return ;;
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
  done
}

settings_prompt_edge_mode() {
  cat >/dev/tty <<'EOF'

How does HTTPS traffic reach this server?
  1) Directly: this server gets its own Let's Encrypt certificate.
     Forward 80/tcp, 443/tcp and 3478/udp to this host.
  2) Through an existing reverse proxy (Nginx Proxy Manager, nginx, ...).
     The proxy terminates TLS and forwards plain HTTP to port 80 of this host.
     Forward 3478/udp to this host.
EOF
  local choice
  prompt choice "Choice" is_choice_1_or_2 1
  if [[ $choice == 1 ]]; then
    EDGE_PROXY=builtin
  else
    EDGE_PROXY=external
  fi
}
is_choice_1_or_2() { [[ $1 == 1 || $1 == 2 ]]; }

# Fills every missing required setting interactively.
settings_prompt_missing() {
  if [[ -z ${NETBIRD_DOMAIN:-} ]]; then
    prompt NETBIRD_DOMAIN "Public domain name for NetBird (e.g. vpn.example.com)" is_fqdn
  fi
  if [[ -z ${EDGE_PROXY:-} ]]; then
    settings_prompt_edge_mode
  fi
  if [[ $EDGE_PROXY == "builtin" && -z ${ACME_EMAIL:-} ]]; then
    prompt ACME_EMAIL "Email for Let's Encrypt expiry notices" is_email
  fi
  if [[ $EDGE_PROXY == "external" && -z ${EXTERNAL_PROXY_IP:-} ]]; then
    prompt EXTERNAL_PROXY_IP "IPv4 of the reverse proxy, as seen from this host" is_ipv4
  fi
  if [[ -z ${ENABLE_FAIL2BAN:-} ]]; then
    if prompt_yes_no "Ban SSH brute-force sources with fail2ban?" true; then
      ENABLE_FAIL2BAN=true
      prompt FAIL2BAN_IGNORE_IPS "IPs/CIDRs never to ban, space separated (your admin network)" \
        is_ipv4_list "${FAIL2BAN_IGNORE_IPS:-}"
    else
      ENABLE_FAIL2BAN=false
    fi
  fi
}

settings_missing() {
  [[ -z ${NETBIRD_DOMAIN:-} || -z ${EDGE_PROXY:-} || -z ${ENABLE_FAIL2BAN:-} ]] && return 0
  [[ $EDGE_PROXY == "builtin" && -z ${ACME_EMAIL:-} ]] && return 0
  [[ $EDGE_PROXY == "external" && -z ${EXTERNAL_PROXY_IP:-} ]] && return 0
  return 1
}

settings_validate() {
  is_fqdn "$NETBIRD_DOMAIN" || die "NETBIRD_DOMAIN '$NETBIRD_DOMAIN' is not a valid domain name."
  is_edge_mode "$EDGE_PROXY" || die "EDGE_PROXY must be 'builtin' or 'external', got '$EDGE_PROXY'."
  if [[ $EDGE_PROXY == "builtin" ]]; then
    is_email "$ACME_EMAIL" || die "ACME_EMAIL '$ACME_EMAIL' is not a valid email address."
  else
    is_ipv4 "$EXTERNAL_PROXY_IP" || die "EXTERNAL_PROXY_IP '$EXTERNAL_PROXY_IP' is not a valid IPv4 address."
  fi
  is_boolean "$ENABLE_FAIL2BAN" || die "ENABLE_FAIL2BAN must be 'true' or 'false'."
  is_ipv4_list "$FAIL2BAN_IGNORE_IPS" || die "FAIL2BAN_IGNORE_IPS '$FAIL2BAN_IGNORE_IPS' is not a list of IPv4 addresses/CIDRs."
  if ! getent ahostsv4 "$NETBIRD_DOMAIN" >/dev/null; then
    log_warn "$NETBIRD_DOMAIN does not resolve yet: clients cannot connect until it does."
  fi
}

readonly SAVED_SETTINGS=(NETBIRD_DOMAIN EDGE_PROXY ACME_EMAIL EXTERNAL_PROXY_IP ENABLE_FAIL2BAN FAIL2BAN_IGNORE_IPS)

# Updates the saved keys in place, so any other key the operator added is kept.
settings_save() {
  if [[ ! -f $SETTINGS_FILE ]]; then
    install -m 0600 /dev/null "$SETTINGS_FILE"
    echo "# Written by install.sh. Edit, then re-run install.sh to apply." >"$SETTINGS_FILE"
  fi
  local key line
  for key in "${SAVED_SETTINGS[@]}"; do
    line="$key=\"${!key:-}\""
    if grep -q "^$key=" "$SETTINGS_FILE"; then
      sed -i "s|^$key=.*|$line|" "$SETTINGS_FILE"
    else
      echo "$line" >>"$SETTINGS_FILE"
    fi
  done
  log_info "Settings saved to $SETTINGS_FILE."
}

settings_print() {
  echo
  echo "  Domain:      $NETBIRD_DOMAIN"
  if [[ $EDGE_PROXY == "builtin" ]]; then
    echo "  Edge mode:   direct, Let's Encrypt ($ACME_EMAIL)"
  else
    echo "  Edge mode:   behind reverse proxy $EXTERNAL_PROXY_IP"
  fi
  echo "  fail2ban:    $ENABLE_FAIL2BAN${FAIL2BAN_IGNORE_IPS:+ (never ban: $FAIL2BAN_IGNORE_IPS)}"
  echo
}

settings_load() {
  if [[ -f $SETTINGS_FILE ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$SETTINGS_FILE"
    set +a
  fi

  if settings_missing; then
    has_tty || die "Missing settings and no terminal to ask: create $SETTINGS_FILE (see netbird.env.example)."
    settings_prompt_missing
    settings_print
    prompt_yes_no "Install with these settings?" true || die "Aborted."
    settings_save
  fi

  export NETBIRD_DOMAIN EDGE_PROXY ENABLE_FAIL2BAN
  export ACME_EMAIL=${ACME_EMAIL:-}
  export EXTERNAL_PROXY_IP=${EXTERNAL_PROXY_IP:-}
  export FAIL2BAN_IGNORE_IPS=${FAIL2BAN_IGNORE_IPS:-}
  export INSTALL_DIR=${INSTALL_DIR:-/opt/netbird}
  export NETBIRD_SERVER_IMAGE=${NETBIRD_SERVER_IMAGE:-$DEFAULT_NETBIRD_SERVER_IMAGE}
  export DASHBOARD_IMAGE=${DASHBOARD_IMAGE:-$DEFAULT_DASHBOARD_IMAGE}
  export TRAEFIK_IMAGE=${TRAEFIK_IMAGE:-$DEFAULT_TRAEFIK_IMAGE}
  export NETBIRD_SUBNET=${NETBIRD_SUBNET:-172.30.0.0/24}
  export TRAEFIK_IP=${TRAEFIK_IP:-172.30.0.10}

  settings_validate
}
