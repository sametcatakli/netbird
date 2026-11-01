# shellcheck shell=bash
# Shared helpers sourced by install.sh and the lib/*.sh modules.

readonly COLOR_RESET=$'\033[0m'
readonly COLOR_BLUE=$'\033[1;34m'
readonly COLOR_YELLOW=$'\033[1;33m'
readonly COLOR_RED=$'\033[1;31m'

log_info()  { printf '%s[INFO]%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "This installer must be run as root."
}

require_almalinux() {
  [[ -r /etc/os-release ]] || die "Cannot detect the operating system."
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ $ID == "almalinux" ]] || die "Unsupported OS '$ID': AlmaLinux 9 or 10 is required."
  case ${VERSION_ID%%.*} in
    9|10) ;;
    *) die "Unsupported AlmaLinux version '$VERSION_ID': 9 or 10 is required." ;;
  esac
}

# Installs a file only when its content changed, so re-runs stay idempotent.
# Returns 0 when the file was updated, 1 when it was already up to date.
install_file() {
  local source=$1 target=$2 mode=${3:-0644}
  if [[ -f $target ]] && cmp -s "$source" "$target"; then
    return 1
  fi
  install -D -m "$mode" -o root -g root "$source" "$target"
  restorecon -F "$target" 2>/dev/null || true
  return 0
}

random_base64() {
  openssl rand -base64 32
}
