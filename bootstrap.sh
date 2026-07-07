#!/usr/bin/env bash
set -euo pipefail

readonly GITHUB_HOST="github.com"
readonly DEFAULT_CHEZMOI_INSTALL_DIR="$HOME/.local/bin"
readonly DEFAULT_DOTFILES_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/chezmoi"
readonly BASE_PACKAGES=(git curl gh ansible xdg-utils)
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

is_wsl() {
  grep -qiE "(microsoft|wsl)" /proc/version /proc/sys/kernel/osrelease 2>/dev/null
}

check_wsl_environment() {
  if is_wsl; then
    return 0
  fi

  warn "This script is intended for WSL."
  warn "Running it on native Linux is not guaranteed to work."
  confirm_continue "Continue anyway?"
}

check_supported_os() {
  if [ ! -r /etc/os-release ]; then
    error "Cannot determine the OS because /etc/os-release is not readable."
    exit 1
  fi

  . /etc/os-release

  if [ "${ID:-}" = "debian" ]; then
    return 0
  fi

  if command_exists apt-get; then
    warn "This script is intended for Debian."
    warn "Detected OS: ${PRETTY_NAME:-unknown}"
    warn "Continuing as an apt-based environment, but full compatibility is not guaranteed."
    confirm_continue "Continue anyway?"
    return 0
  fi

  error "This script is intended for Debian or other apt-based Linux systems."
  error "Detected OS: ${PRETTY_NAME:-unknown}"
  exit 1
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
  if command_exists xdg-open; then
    export GH_BROWSER="${GH_BROWSER:-xdg-open}"
    gh config set browser xdg-open
    return 0
  fi

  if [ -x /mnt/c/Windows/explorer.exe ]; then
    export GH_BROWSER="${GH_BROWSER:-/mnt/c/Windows/explorer.exe}"
    gh config set browser /mnt/c/Windows/explorer.exe
    return 0
  fi

  warn "No browser opener was found. GitHub CLI may not be able to open the Windows browser."
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
  sudo apt-get install -y "${BASE_PACKAGES[@]}"
  echo "Base packages installed."
}

main() {
  trap cleanup EXIT

  check_wsl_environment
  check_supported_os
  initialize_sudo
  install_base_packages
  install_chezmoi
  configure_github_cli_browser
  ensure_github_auth
  ensure_github_known_host
  clone_dotfiles_repository
  run_ansible_if_present "$DOTFILES_SOURCE_DIR"
  run_chezmoi_if_present "$DOTFILES_SOURCE_DIR"
  reload_or_notice_tmux
}

if (( ${#BASH_SOURCE[@]} == 0 )) || [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
