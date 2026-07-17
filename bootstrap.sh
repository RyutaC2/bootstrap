#!/usr/bin/env bash
set -euo pipefail

readonly GITHUB_HOST="github.com"
readonly DEFAULT_CHEZMOI_INSTALL_DIR="$HOME/.local/bin"
readonly DEFAULT_DOTFILES_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/chezmoi"
readonly DEFAULT_WINDOWS_BROWSER="/mnt/c/Windows/explorer.exe"
readonly BASE_PACKAGES=(git curl gh ansible xdg-utils)
readonly UBUNTU_REPOSITORY_PACKAGES=(software-properties-common)
readonly SUPPORTED_DEBIAN_VERSIONS=(12 13)
readonly SUPPORTED_UBUNTU_VERSIONS=(22.04 24.04 26.04)
readonly ANSIBLE_PLAYBOOK_CANDIDATES=(
  ansible/playbook.yml
  ansible/playbook.yaml
  ansible/site.yml
  ansible/site.yaml
  playbook.yml
  playbook.yaml
  site.yml
  site.yaml
)

CHEZMOI_BIN="chezmoi"
DOTFILES_SOURCE_DIR=""
SUDO_KEEPALIVE_PID=""
CLONE_DESTINATION_CREATED=""
CLONE_COMPLETED=0
PLATFORM_ID=""
PLATFORM_VERSION=""
PLATFORM_PRETTY_NAME=""
PLATFORM_ARCHITECTURE=""
PLATFORM_KIND=""
PLATFORM_IS_WSL=0
PLATFORM_IS_WSL2=0

warn() {
  echo "Warning: $*" >&2
}

error() {
  echo "Error: $*" >&2
}

abort() {
  echo "Aborted."
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

cleanup() {
  if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
    kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi

  if [ -n "${CLONE_DESTINATION_CREATED:-}" ] && [ "${CLONE_COMPLETED:-0}" != "1" ] && [ -e "$CLONE_DESTINATION_CREATED" ]; then
    echo "Removing incomplete clone: $CLONE_DESTINATION_CREATED" >&2
    rm -rf -- "$CLONE_DESTINATION_CREATED"
  fi
}

prompt_read() {
  local variable_name="$1"
  local prompt="$2"
  local value

  if [ -r /dev/tty ]; then
    read -r -p "$prompt" value </dev/tty || return 1
  else
    read -r -p "$prompt" value || return 1
  fi

  printf -v "$variable_name" '%s' "$value"
}

confirm_continue() {
  local prompt="$1"
  local answer

  prompt_read answer "${prompt} [y/N] "
  case "$answer" in
  y | Y | yes | YES | Yes)
    return 0
    ;;
  *)
    abort
    ;;
  esac
}

initialize_sudo() {
  echo "Preparing sudo credentials. You may be asked for your password once."
  sudo -v

  while true; do
    sleep 60
    sudo -n true 2>/dev/null || exit
  done &
  SUDO_KEEPALIVE_PID="$!"
}

value_in_array() {
  local wanted="$1"
  shift
  local candidate

  for candidate in "$@"; do
    if [ "$candidate" = "$wanted" ]; then
      return 0
    fi
  done

  return 1
}

read_os_release() {
  local os_release_file="$1"
  local -a os_values

  if [ ! -r "$os_release_file" ]; then
    error "Cannot determine the OS because $os_release_file is not readable."
    return 1
  fi

  mapfile -t os_values < <(
    set +u
    # shellcheck disable=SC1090
    . "$os_release_file"
    printf '%s\n' "${ID:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-unknown}"
  )

  PLATFORM_ID="${os_values[0]:-}"
  PLATFORM_VERSION="${os_values[1]:-}"
  PLATFORM_PRETTY_NAME="${os_values[2]:-unknown}"
}

detect_wsl_generation() {
  local kernel_release_file="$1"

  PLATFORM_IS_WSL=0
  PLATFORM_IS_WSL2=0

  if [ ! -r "$kernel_release_file" ]; then
    return 0
  fi

  if grep -qiE '(microsoft|wsl)' "$kernel_release_file" 2>/dev/null; then
    PLATFORM_IS_WSL=1
  fi

  if grep -qiE '(wsl2|microsoft-standard)' "$kernel_release_file" 2>/dev/null; then
    PLATFORM_IS_WSL2=1
  fi
}

detect_architecture() {
  local architecture="${1:-}"

  if [ -z "$architecture" ]; then
    if ! command_exists dpkg; then
      error "Cannot determine the package architecture because dpkg is unavailable."
      return 1
    fi
    architecture="$(dpkg --print-architecture)"
  fi

  PLATFORM_ARCHITECTURE="$architecture"
}

detect_supported_platform() {
  local os_release_file="${1:-/etc/os-release}"
  local kernel_release_file="${2:-/proc/sys/kernel/osrelease}"
  local architecture="${3:-}"

  PLATFORM_KIND=""
  read_os_release "$os_release_file" || return 1
  detect_wsl_generation "$kernel_release_file"
  detect_architecture "$architecture" || return 1

  if [ "$PLATFORM_ARCHITECTURE" != "amd64" ]; then
    error "Unsupported architecture: $PLATFORM_ARCHITECTURE (supported: amd64)."
    return 1
  fi

  case "$PLATFORM_ID" in
  debian)
    if ! value_in_array "$PLATFORM_VERSION" "${SUPPORTED_DEBIAN_VERSIONS[@]}"; then
      error "Unsupported Debian version: ${PLATFORM_VERSION:-unknown} (supported: ${SUPPORTED_DEBIAN_VERSIONS[*]})."
      return 1
    fi
    if [ "$PLATFORM_IS_WSL" -eq 1 ]; then
      error "Debian on WSL is not supported. Use Debian 12/13 on native Linux or a supported Ubuntu release on WSL 2."
      return 1
    fi
    PLATFORM_KIND="debian-native"
    ;;
  ubuntu)
    if ! value_in_array "$PLATFORM_VERSION" "${SUPPORTED_UBUNTU_VERSIONS[@]}"; then
      error "Unsupported Ubuntu version: ${PLATFORM_VERSION:-unknown} (supported LTS: ${SUPPORTED_UBUNTU_VERSIONS[*]})."
      return 1
    fi
    if [ "$PLATFORM_IS_WSL" -eq 1 ] && [ "$PLATFORM_IS_WSL2" -ne 1 ]; then
      error "Ubuntu on WSL 1 is not supported. Convert the distribution to WSL 2 before running bootstrap."
      return 1
    fi
    if [ "$PLATFORM_IS_WSL2" -eq 1 ]; then
      PLATFORM_KIND="ubuntu-wsl2"
    else
      PLATFORM_KIND="ubuntu-native"
    fi
    ;;
  *)
    error "Unsupported OS: ${PLATFORM_PRETTY_NAME:-unknown}."
    error "Supported environments are Debian 12/13 native and Ubuntu ${SUPPORTED_UBUNTU_VERSIONS[*]} native or WSL 2."
    return 1
    ;;
  esac

  if ! command_exists apt-get; then
    error "apt-get is required on supported Debian and Ubuntu environments."
    return 1
  fi

  echo "Detected supported environment: $PLATFORM_KIND ($PLATFORM_PRETTY_NAME, $PLATFORM_ARCHITECTURE)."
}

configure_github_git_protocol() {
  gh config set git_protocol ssh --host "$GITHUB_HOST"
  gh auth setup-git --hostname "$GITHUB_HOST"
}

ensure_github_auth() {
  if gh auth status --hostname "$GITHUB_HOST" >/dev/null 2>&1; then
    configure_github_git_protocol
    return 0
  fi

  echo "GitHub CLI authentication is required to clone your private repository."
  echo "A browser should open automatically for GitHub authentication."
  echo "If it does not open, follow the URL printed by GitHub CLI."
  gh auth login --hostname "$GITHUB_HOST" --web --git-protocol ssh
  configure_github_git_protocol
}

ensure_github_known_host() {
  local ssh_dir="$HOME/.ssh"
  local known_hosts="$ssh_dir/known_hosts"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$known_hosts"
  chmod 600 "$known_hosts"

  if ssh-keygen -F "$GITHUB_HOST" -f "$known_hosts" >/dev/null 2>&1; then
    return 0
  fi

  cat >>"$known_hosts" <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
EOF
}

configure_github_cli_browser() {
  local windows_browser="$1"

  if [ -n "${GH_BROWSER:-}" ]; then
    return 0
  fi

  if [ "$PLATFORM_KIND" = "ubuntu-wsl2" ]; then
    if [ -x "$windows_browser" ]; then
      export GH_BROWSER="$windows_browser"
      gh config set browser "$windows_browser"
      return 0
    fi
    warn "Windows browser opener was not found at $windows_browser."
  fi

  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command_exists xdg-open; then
    export GH_BROWSER="xdg-open"
    gh config set browser xdg-open
    return 0
  fi

  warn "No graphical browser opener was configured. Use the URL and device code printed by GitHub CLI."
}

install_chezmoi() {
  if command_exists chezmoi; then
    CHEZMOI_BIN="$(command -v chezmoi)"
    return 0
  fi

  echo "Installing chezmoi to $DEFAULT_CHEZMOI_INSTALL_DIR."
  mkdir -p "$DEFAULT_CHEZMOI_INSTALL_DIR"
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$DEFAULT_CHEZMOI_INSTALL_DIR"
  export PATH="$DEFAULT_CHEZMOI_INSTALL_DIR:$PATH"
  CHEZMOI_BIN="$DEFAULT_CHEZMOI_INSTALL_DIR/chezmoi"
}

resolve_dotfiles_repo() {
  local repo="${DOTFILES_REPO:-}"

  while [ -z "$repo" ]; do
    prompt_read repo "chezmoi source repository to clone (owner/repo): "
  done

  printf '%s\n' "$repo"
}

clone_dotfiles_repository() {
  local repo
  local destination="${DOTFILES_DIR:-$DEFAULT_DOTFILES_DIR}"

  repo="$(resolve_dotfiles_repo)"

  if [ -e "$destination" ]; then
    error "chezmoi source directory already exists: $destination"
    exit 1
  fi

  mkdir -p "$(dirname "$destination")"
  CLONE_DESTINATION_CREATED="$destination"
  CLONE_COMPLETED=0

  if ! gh repo clone "$repo" "$destination"; then
    error "Failed to clone chezmoi source repository."
    exit 1
  fi

  CLONE_COMPLETED=1
  DOTFILES_SOURCE_DIR="$destination"
  echo "chezmoi source repository cloned to $destination."
}

find_ansible_playbook() {
  local source_dir="$1"
  local candidate

  for candidate in "${ANSIBLE_PLAYBOOK_CANDIDATES[@]}"; do
    if [ -f "$source_dir/$candidate" ]; then
      printf '%s\n' "$source_dir/$candidate"
      return 0
    fi
  done

  return 1
}

find_ansible_inventory() {
  local source_dir="$1"
  local candidate="$source_dir/ansible/inventory"

  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

run_ansible_if_present() {
  local source_dir="$1"
  local inventory
  local playbook

  if playbook="$(find_ansible_playbook "$source_dir")"; then
    echo "Running Ansible playbook: $playbook"
    echo "Ansible will ask for your sudo password if privilege escalation is required."
    if inventory="$(find_ansible_inventory "$source_dir")"; then
      ansible-playbook --ask-become-pass -i "$inventory" "$playbook"
    else
      ansible-playbook --ask-become-pass -i localhost, --connection local "$playbook"
    fi
    return 0
  fi

  echo "No Ansible playbook found. Skipping Ansible setup."
}

run_chezmoi_if_present() {
  local source_dir="$1"

  if [ ! -d "$source_dir" ]; then
    echo "No chezmoi source directory found. Skipping chezmoi apply." >&2
    return 0
  fi

  if [ "${BOOTSTRAP_YES:-}" = "1" ]; then
    echo "Apply chezmoi changes? [y/N] y (BOOTSTRAP_YES=1)"
  else
    confirm_continue "Apply chezmoi changes?"
  fi

  "$CHEZMOI_BIN" --source "$source_dir" apply
}

reload_or_notice_tmux() {
  if ! command_exists tmux; then
    warn "tmux is not installed. If Ansible failed, check the setup log."
    return 0
  fi

  if tmux has-session >/dev/null 2>&1; then
    tmux source-file "$HOME/.tmux.conf"
    echo "Reloaded tmux config for the running tmux server."
    return 0
  fi

  echo "No running tmux server found; skipping tmux reload."
  echo "Your tmux config will be loaded automatically the next time tmux starts."
}

install_base_packages() {
  sudo apt-get update

  if [ "$PLATFORM_ID" = "ubuntu" ]; then
    sudo apt-get install -y "${UBUNTU_REPOSITORY_PACKAGES[@]}"
    sudo add-apt-repository -y universe
    sudo apt-get update
  fi

  sudo apt-get install -y "${BASE_PACKAGES[@]}"
  echo "Base packages installed."
}

# Optional path/architecture arguments are used by tests to supply fixtures.
# Production execution calls this function without arguments.
# shellcheck disable=SC2120
run_bootstrap() {
  local os_release_file="${1:-/etc/os-release}"
  local kernel_release_file="${2:-/proc/sys/kernel/osrelease}"
  local architecture="${3:-}"

  detect_supported_platform "$os_release_file" "$kernel_release_file" "$architecture" || return 1
  initialize_sudo
  install_base_packages
  install_chezmoi
  configure_github_cli_browser "$DEFAULT_WINDOWS_BROWSER"
  ensure_github_auth
  ensure_github_known_host
  clone_dotfiles_repository
  run_ansible_if_present "$DOTFILES_SOURCE_DIR"
  run_chezmoi_if_present "$DOTFILES_SOURCE_DIR"
  reload_or_notice_tmux
}

main() {
  trap cleanup EXIT
  # shellcheck disable=SC2119
  run_bootstrap
}

if ((${#BASH_SOURCE[@]} == 0)) || [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
