#!/usr/bin/env bash
set -euo pipefail
CHEZMOI_BIN="chezmoi"
DOTFILES_SOURCE_DIR=""
SUDO_KEEPALIVE_PID=""
CLONE_DESTINATION_CREATED=""
CLONE_COMPLETED=0

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

trap cleanup EXIT

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
      echo "Aborted."
      exit 1
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

  echo "Warning: This script is intended for WSL." >&2
  echo "Running it on native Linux is not guaranteed to work." >&2
  confirm_continue "Continue anyway?"
}

check_supported_os() {
  if [ ! -r /etc/os-release ]; then
    echo "Error: Cannot determine the OS because /etc/os-release is not readable." >&2
    exit 1
  fi

  . /etc/os-release

  if [ "${ID:-}" = "debian" ]; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    echo "Warning: This script is intended for Debian." >&2
    echo "Detected OS: ${PRETTY_NAME:-unknown}" >&2
    echo "Continuing as an apt-based environment, but full compatibility is not guaranteed." >&2
    confirm_continue "Continue anyway?"
    return 0
  fi

  echo "Error: This script is intended for Debian or other apt-based Linux systems." >&2
  echo "Detected OS: ${PRETTY_NAME:-unknown}" >&2
  exit 1
}

ensure_github_auth() {
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    gh config set git_protocol ssh --host github.com
    gh auth setup-git --hostname github.com
    return 0
  fi

  echo "GitHub CLI authentication is required to clone your private repository."
  echo "A browser should open automatically for GitHub authentication."
  echo "If it does not open, follow the URL printed by GitHub CLI."
  gh auth login --hostname github.com --web --git-protocol ssh
  gh auth setup-git --hostname github.com
}

ensure_github_known_host() {
  local ssh_dir="$HOME/.ssh"
  local known_hosts="$ssh_dir/known_hosts"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$known_hosts"
  chmod 600 "$known_hosts"

  if ssh-keygen -F github.com -f "$known_hosts" >/dev/null 2>&1; then
    return 0
  fi

  cat >>"$known_hosts" <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
EOF
}

configure_github_cli_browser() {
  if command -v xdg-open >/dev/null 2>&1; then
    export GH_BROWSER="${GH_BROWSER:-xdg-open}"
    gh config set browser xdg-open
    return 0
  fi

  if [ -x /mnt/c/Windows/explorer.exe ]; then
    export GH_BROWSER="${GH_BROWSER:-/mnt/c/Windows/explorer.exe}"
    gh config set browser /mnt/c/Windows/explorer.exe
    return 0
  fi

  echo "Warning: No browser opener was found. GitHub CLI may not be able to open the Windows browser." >&2
}

install_chezmoi() {
  if command -v chezmoi >/dev/null 2>&1; then
    CHEZMOI_BIN="$(command -v chezmoi)"
    return 0
  fi

  echo "Installing chezmoi to $HOME/.local/bin."
  mkdir -p "$HOME/.local/bin"
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
  CHEZMOI_BIN="$HOME/.local/bin/chezmoi"
}

clone_dotfiles_repository() {
  local repo="${DOTFILES_REPO:-}"
  local destination="${DOTFILES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/chezmoi}"

  while [ -z "$repo" ]; do
    prompt_read repo "chezmoi source repository to clone (owner/repo): "
  done

  if [ -e "$destination" ]; then
    echo "Error: chezmoi source directory already exists: $destination" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$destination")"
  CLONE_DESTINATION_CREATED="$destination"
  CLONE_COMPLETED=0

  if ! gh repo clone "$repo" "$destination"; then
    echo "Error: Failed to clone chezmoi source repository." >&2
    exit 1
  fi

  CLONE_COMPLETED=1
  DOTFILES_SOURCE_DIR="$destination"
  echo "chezmoi source repository cloned to $destination."
}

find_ansible_playbook() {
  local source_dir="$1"
  local candidate

  for candidate in \
    "$source_dir/ansible/playbook.yml" \
    "$source_dir/ansible/playbook.yaml" \
    "$source_dir/ansible/site.yml" \
    "$source_dir/ansible/site.yaml" \
    "$source_dir/playbook.yml" \
    "$source_dir/playbook.yaml" \
    "$source_dir/site.yml" \
    "$source_dir/site.yaml"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
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
    if inventory="$(find_ansible_inventory "$source_dir")"; then
      ansible-playbook -i "$inventory" "$playbook"
    else
      ansible-playbook -i localhost, --connection local "$playbook"
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

  echo "Showing chezmoi diff from $source_dir."
  "$CHEZMOI_BIN" --source "$source_dir" diff || true

  if [ "${BOOTSTRAP_YES:-}" = "1" ]; then
    echo "Apply chezmoi changes? [y/N] y (BOOTSTRAP_YES=1)"
  else
    confirm_continue "Apply chezmoi changes?"
  fi

  "$CHEZMOI_BIN" --source "$source_dir" apply
}

reload_or_notice_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is not installed. If Ansible failed, check the setup log." >&2
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

check_wsl_environment
check_supported_os
initialize_sudo

sudo apt-get update
sudo apt-get install -y git curl gh ansible xdg-utils

echo "Base packages installed."
install_chezmoi
configure_github_cli_browser
ensure_github_auth
ensure_github_known_host
clone_dotfiles_repository
run_ansible_if_present "$DOTFILES_SOURCE_DIR"
run_chezmoi_if_present "$DOTFILES_SOURCE_DIR"
reload_or_notice_tmux
