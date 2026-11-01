# shellcheck shell=bash
# NetBird stack: edge mode, secrets, rendered configuration and service lifecycle.

# shellcheck disable=SC2016 # literal names for envsubst
readonly TEMPLATE_VARIABLES='${NETBIRD_DOMAIN} ${ACME_EMAIL} ${TRAEFIK_IP} ${NETBIRD_SUBNET}
  ${TRAEFIK_IMAGE} ${DASHBOARD_IMAGE} ${NETBIRD_SERVER_IMAGE}
  ${RELAY_AUTH_SECRET} ${DATASTORE_ENCRYPTION_KEY} ${SESSION_COOKIE_ENCRYPTION_KEY}
  ${TRAEFIK_PORTS} ${TRAEFIK_ENTRYPOINT} ${TRUSTED_HTTP_PROXIES} ${CLIENT_IP_DEPTH}
  ${UPSTREAM_SOURCE_RANGE} ${EXTERNAL_PROXY_IP} ${NETBIRD_HOST_IP}'
readonly READINESS_TIMEOUT_SECONDS=180

# Exports the settings that differ between edge modes; templates stay mode-agnostic.
netbird_select_edge_mode() {
  export NETBIRD_HOST_IP
  NETBIRD_HOST_IP=$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
  if [[ $EDGE_PROXY == "builtin" ]]; then
    export TRAEFIK_PORTS='["80:80", "443:443"]'
    export TRAEFIK_ENTRYPOINT=websecure
    export TRUSTED_HTTP_PROXIES="[\"$TRAEFIK_IP/32\"]"
    export CLIENT_IP_DEPTH=0
    export UPSTREAM_SOURCE_RANGE='["0.0.0.0/0"]'
  else
    export TRAEFIK_PORTS='["80:80"]'
    export TRAEFIK_ENTRYPOINT=web
    export TRUSTED_HTTP_PROXIES="[\"$TRAEFIK_IP/32\", \"$EXTERNAL_PROXY_IP/32\"]"
    # The upstream proxy appends the real client address as the last X-Forwarded-For entry.
    export CLIENT_IP_DEPTH=1
    export UPSTREAM_SOURCE_RANGE="[\"$EXTERNAL_PROXY_IP/32\"]"
  fi
}

# Prints "template-path rendered-name" pairs for the active edge mode.
netbird_template_map() {
  cat <<EOF
docker-compose.yml docker-compose.yml
config.yaml config.yaml
dashboard.env dashboard.env
traefik/dynamic.yml traefik-dynamic.yml
traefik/static-$EDGE_PROXY.yml traefik.yml
EOF
  if [[ $EDGE_PROXY == "external" ]]; then
    echo "upstream-nginx.conf upstream-nginx.conf"
  fi
}

# Secrets are generated once and reused: rotating the datastore key would make
# the existing database unreadable.
netbird_load_secrets() {
  local secrets_file=$INSTALL_DIR/secrets.env
  if [[ ! -f $secrets_file ]]; then
    log_info "Generating NetBird secrets..."
    (
      umask 077
      cat >"$secrets_file" <<EOF
RELAY_AUTH_SECRET=$(random_base64)
DATASTORE_ENCRYPTION_KEY=$(random_base64)
SESSION_COOKIE_ENCRYPTION_KEY=$(random_base64)
EOF
    )
  fi
  set -a
  # shellcheck source=/dev/null
  . "$secrets_file"
  set +a
}

# Sets CONFIG_CHANGED=true when any rendered file differs from the deployed one.
netbird_render_configuration() {
  log_info "Rendering configuration into $INSTALL_DIR..."
  local template target rendered
  CONFIG_CHANGED=false
  while read -r template target; do
    rendered=$(mktemp)
    envsubst "$TEMPLATE_VARIABLES" <"$REPO_DIR/templates/$template" >"$rendered"
    if install_file "$rendered" "$INSTALL_DIR/$target" 0600; then
      CONFIG_CHANGED=true
    fi
    rm -f "$rendered"
  done < <(netbird_template_map)
}

# Builtin mode checks the full public path, TLS included. In external mode TLS
# lives upstream, so the check runs from the edge router to the server.
netbird_is_ready() {
  local path=/oauth2/.well-known/openid-configuration
  if [[ $EDGE_PROXY == "builtin" ]]; then
    curl -fsS -o /dev/null --resolve "$NETBIRD_DOMAIN:443:127.0.0.1" "https://$NETBIRD_DOMAIN$path"
  else
    docker exec netbird-traefik wget -q -O /dev/null "http://netbird-server:80$path"
  fi
}

netbird_setup_required() {
  docker exec netbird-traefik wget -q -O - http://netbird-server:80/api/instance 2>/dev/null \
    | grep -q '"setup_required":true'
}

netbird_wait_until_ready() {
  log_info "Waiting for NetBird to become ready..."
  local deadline=$((SECONDS + READINESS_TIMEOUT_SECONDS))
  until netbird_is_ready 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      docker compose --project-directory "$INSTALL_DIR" logs --tail=30
      die "NetBird did not become ready within ${READINESS_TIMEOUT_SECONDS}s (DNS, open ports and TLS are the usual suspects)."
    fi
    sleep 5
  done
}

netbird_start() {
  log_info "Pulling images and starting the NetBird stack..."
  local recreate=()
  # Rewritten files get a new inode that running containers would never see.
  if [[ $CONFIG_CHANGED == "true" ]]; then
    recreate=(--force-recreate)
  fi
  docker compose --project-directory "$INSTALL_DIR" pull --quiet
  docker compose --project-directory "$INSTALL_DIR" up -d --remove-orphans "${recreate[@]}"
  netbird_wait_until_ready
}

netbird_setup() {
  netbird_select_edge_mode
  install -d -m 0700 -o root -g root "$INSTALL_DIR"
  netbird_load_secrets
  netbird_render_configuration
  netbird_start
}
