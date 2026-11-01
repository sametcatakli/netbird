# shellcheck shell=bash
# Docker Engine from the official repository, with a hardened daemon configuration.

readonly DOCKER_REPO_URL=https://download.docker.com/linux/rhel/docker-ce.repo
readonly DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-compose-plugin container-selinux)
# These conflict with containerd.io on Enterprise Linux.
readonly DOCKER_CONFLICTING_PACKAGES=(podman buildah runc)

docker_install() {
  if rpm -q docker-ce >/dev/null 2>&1; then
    return
  fi
  log_info "Installing Docker Engine..."
  dnf -y remove "${DOCKER_CONFLICTING_PACKAGES[@]}" >/dev/null 2>&1 || true
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo "$DOCKER_REPO_URL"
  dnf -y install "${DOCKER_PACKAGES[@]}"
}

docker_configure() {
  log_info "Applying the hardened Docker daemon configuration..."
  if install_file "$REPO_DIR/config/docker/daemon.json" /etc/docker/daemon.json; then
    systemctl restart docker 2>/dev/null || true
  fi
  systemctl enable --now docker
  docker compose version >/dev/null || die "The Docker Compose plugin is not available."
}

docker_setup() {
  docker_install
  docker_configure
}
