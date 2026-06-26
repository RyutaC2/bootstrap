#!/usr/bin/env bash
set -euo pipefail
CHEZMOI_BIN="chezmoi"

confirm_continue() {
  local prompt="$1"
  local answer

  read -r -p "${prompt} [y/N] " answer
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
  local requested_destination

  while [ -z "$repo" ]; do
    read -r -p "chezmoi source repository to clone (owner/repo): " repo
  done

  read -r -p "chezmoi source directory [${destination}]: " requested_destination
  destination="${requested_destination:-$destination}"

  if [ -e "$destination" ]; then
    echo "Error: chezmoi source directory already exists: $destination" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$destination")"
  gh repo clone "$repo" "$destination"
  echo "chezmoi source repository cloned to $destination."
  echo "Next steps:"
  echo "$CHEZMOI_BIN diff"
  echo "$CHEZMOI_BIN apply"
}

check_wsl_environment
check_supported_os

sudo apt-get update
sudo apt-get install -y git curl gh

echo "Base packages installed."
install_chezmoi
ensure_github_auth
clone_dotfiles_repository
