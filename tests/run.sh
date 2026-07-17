#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-tests.XXXXXX")"
original_path="$PATH"
test_count=0
passed=0
failed=0

cleanup_tests() {
  rm -rf -- "$tmp_root"
}
trap cleanup_tests EXIT HUP INT TERM

# shellcheck source=bootstrap.sh
source "$repo_dir/bootstrap.sh"

pass() {
  test_count=$((test_count + 1))
  passed=$((passed + 1))
  printf 'ok %d - %s\n' "$test_count" "$1"
}

fail() {
  test_count=$((test_count + 1))
  failed=$((failed + 1))
  printf 'not ok %d - %s\n' "$test_count" "$1" >&2
}

assert_equal() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"

  if [ "$actual" = "$expected" ]; then
    pass "$test_name"
  else
    fail "$test_name"
    printf '  expected: %s\n' "$expected" >&2
    printf '  actual:   %s\n' "$actual" >&2
  fi
}

assert_file_contains() {
  local test_name="$1"
  local needle="$2"
  local file="$3"

  if [ -r "$file" ] && grep -F -- "$needle" "$file" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
    printf '  missing from %s: %s\n' "$file" "$needle" >&2
  fi
}

assert_file_not_contains() {
  local test_name="$1"
  local needle="$2"
  local file="$3"

  if [ ! -r "$file" ] || ! grep -F -- "$needle" "$file" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
    printf '  unexpected in %s: %s\n' "$file" "$needle" >&2
  fi
}

write_os_release() {
  local file="$1"
  local id="$2"
  local version="$3"
  local pretty_name="$4"

  {
    printf 'ID=%s\n' "$id"
    printf 'VERSION_ID="%s"\n' "$version"
    printf 'PRETTY_NAME="%s"\n' "$pretty_name"
  } >"$file"
}

assert_supported_platform() {
  local test_name="$1"
  local id="$2"
  local version="$3"
  local kernel_release="$4"
  local expected_kind="$5"
  local fixture="$tmp_root/platform-${test_count}-${id}-${version}"

  mkdir -p "$fixture"
  write_os_release "$fixture/os-release" "$id" "$version" "$id $version"
  printf '%s\n' "$kernel_release" >"$fixture/kernel-release"

  if detect_supported_platform "$fixture/os-release" "$fixture/kernel-release" amd64 >"$fixture/output" 2>&1; then
    assert_equal "$test_name" "$expected_kind" "$PLATFORM_KIND"
  else
    fail "$test_name"
    sed 's/^/  /' "$fixture/output" >&2
  fi
}

assert_unsupported_platform() {
  local test_name="$1"
  local id="$2"
  local version="$3"
  local kernel_release="$4"
  local architecture="$5"
  local fixture="$tmp_root/unsupported-${test_count}-${id}-${version}"

  mkdir -p "$fixture"
  write_os_release "$fixture/os-release" "$id" "$version" "$id $version"
  printf '%s\n' "$kernel_release" >"$fixture/kernel-release"

  if detect_supported_platform "$fixture/os-release" "$fixture/kernel-release" "$architecture" >"$fixture/output" 2>&1; then
    fail "$test_name"
  else
    pass "$test_name"
  fi
}

test_supported_platform_matrix() {
  local native_kernel='6.12.0-linux-amd64'
  local wsl2_kernel='5.15.167.4-microsoft-standard-WSL2'

  assert_supported_platform 'accepts Debian 12 native' debian 12 "$native_kernel" debian-native
  assert_supported_platform 'accepts Debian 13 native' debian 13 "$native_kernel" debian-native
  assert_supported_platform 'accepts Ubuntu 22.04 native' ubuntu 22.04 "$native_kernel" ubuntu-native
  assert_supported_platform 'accepts Ubuntu 24.04 native' ubuntu 24.04 "$native_kernel" ubuntu-native
  assert_supported_platform 'accepts Ubuntu 26.04 native' ubuntu 26.04 "$native_kernel" ubuntu-native
  assert_supported_platform 'accepts Ubuntu 22.04 WSL 2' ubuntu 22.04 "$wsl2_kernel" ubuntu-wsl2
  assert_supported_platform 'accepts Ubuntu 24.04 WSL 2' ubuntu 24.04 "$wsl2_kernel" ubuntu-wsl2
  assert_supported_platform 'accepts Ubuntu 26.04 WSL 2' ubuntu 26.04 "$wsl2_kernel" ubuntu-wsl2
}

test_unsupported_platform_matrix() {
  local native_kernel='6.12.0-linux-amd64'
  local wsl1_kernel='4.4.0-19041-Microsoft'
  local wsl2_kernel='5.15.167.4-microsoft-standard-WSL2'

  assert_unsupported_platform 'rejects Debian on WSL' debian 13 "$wsl2_kernel" amd64
  assert_unsupported_platform 'rejects Ubuntu on WSL 1' ubuntu 24.04 "$wsl1_kernel" amd64
  assert_unsupported_platform 'rejects unsupported Ubuntu LTS' ubuntu 20.04 "$native_kernel" amd64
  assert_unsupported_platform 'rejects unsupported Debian version' debian 11 "$native_kernel" amd64
  assert_unsupported_platform 'rejects non-amd64 architecture' ubuntu 24.04 "$native_kernel" arm64
  assert_unsupported_platform 'rejects another distribution' fedora 42 "$native_kernel" amd64
}

create_command_stubs() {
  local stub_dir="$1"

  mkdir -p "$stub_dir"
  cat >"$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$BOOTSTRAP_COMMAND_LOG"
"$@"
EOF
  cat >"$stub_dir/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >>"$BOOTSTRAP_COMMAND_LOG"
EOF
  cat >"$stub_dir/add-apt-repository" <<'EOF'
#!/usr/bin/env bash
printf 'add-apt-repository %s\n' "$*" >>"$BOOTSTRAP_COMMAND_LOG"
EOF
  cat >"$stub_dir/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$BOOTSTRAP_COMMAND_LOG"
EOF
  cat >"$stub_dir/xdg-open" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_dir"/*
}

test_package_installation() {
  local fixture="$tmp_root/packages"
  local stub_dir="$fixture/bin"
  local log_file="$fixture/commands.log"

  create_command_stubs "$stub_dir"
  : >"$log_file"
  PATH="$stub_dir:$original_path"
  BOOTSTRAP_COMMAND_LOG="$log_file"
  export PATH BOOTSTRAP_COMMAND_LOG

  PLATFORM_ID=ubuntu
  install_base_packages >/dev/null
  assert_file_contains 'Ubuntu enables Universe' 'add-apt-repository -y universe' "$log_file"
  assert_file_contains 'Ubuntu installs repository tooling first' 'apt-get install -y software-properties-common' "$log_file"
  assert_file_contains 'Ubuntu installs common bootstrap packages' 'apt-get install -y git curl gh ansible xdg-utils' "$log_file"

  : >"$log_file"
  PLATFORM_ID=debian
  install_base_packages >/dev/null
  assert_file_not_contains 'Debian does not enable Ubuntu Universe' 'add-apt-repository' "$log_file"
  assert_file_contains 'Debian installs common bootstrap packages' 'apt-get install -y git curl gh ansible xdg-utils' "$log_file"

  PATH="$original_path"
  export PATH
}

test_browser_selection() {
  local fixture="$tmp_root/browser"
  local stub_dir="$fixture/bin"
  local log_file="$fixture/commands.log"
  local explorer="$fixture/explorer.exe"

  create_command_stubs "$stub_dir"
  : >"$log_file"
  : >"$explorer"
  chmod +x "$explorer"
  PATH="$stub_dir:$original_path"
  BOOTSTRAP_COMMAND_LOG="$log_file"
  export PATH BOOTSTRAP_COMMAND_LOG

  unset GH_BROWSER DISPLAY WAYLAND_DISPLAY
  PLATFORM_KIND=ubuntu-wsl2
  configure_github_cli_browser "$explorer"
  assert_equal 'WSL uses Windows Explorer' "$explorer" "$GH_BROWSER"
  assert_file_contains 'WSL persists Windows browser opener' "gh config set browser $explorer" "$log_file"

  : >"$log_file"
  unset GH_BROWSER WAYLAND_DISPLAY
  DISPLAY=:0
  export DISPLAY
  PLATFORM_KIND=ubuntu-native
  configure_github_cli_browser "$fixture/missing-explorer"
  assert_equal 'graphical native Linux uses xdg-open' xdg-open "$GH_BROWSER"
  assert_file_contains 'native Linux persists xdg-open' 'gh config set browser xdg-open' "$log_file"

  : >"$log_file"
  unset GH_BROWSER DISPLAY WAYLAND_DISPLAY
  PLATFORM_KIND=debian-native
  configure_github_cli_browser "$fixture/missing-explorer" >"$fixture/headless-output" 2>&1
  assert_equal 'headless Linux leaves GH_BROWSER unset' '' "${GH_BROWSER:-}"
  assert_file_not_contains 'headless Linux does not persist a browser' 'gh config set browser' "$log_file"

  PATH="$original_path"
  export PATH
}

test_unsupported_stops_before_side_effects() {
  local fixture="$tmp_root/early-rejection"
  local stub_dir="$fixture/bin"
  local log_file="$fixture/commands.log"

  create_command_stubs "$stub_dir"
  write_os_release "$fixture/os-release" fedora 42 'Fedora Linux 42'
  printf '%s\n' '6.12.0-linux-amd64' >"$fixture/kernel-release"
  : >"$log_file"
  PATH="$stub_dir:$original_path"
  BOOTSTRAP_COMMAND_LOG="$log_file"
  export PATH BOOTSTRAP_COMMAND_LOG

  if run_bootstrap "$fixture/os-release" "$fixture/kernel-release" amd64 >"$fixture/output" 2>&1; then
    fail 'unsupported platform returns before bootstrap work'
  elif [ -s "$log_file" ]; then
    fail 'unsupported platform returns before bootstrap work'
    sed 's/^/  /' "$log_file" >&2
  else
    pass 'unsupported platform returns before bootstrap work'
  fi

  PATH="$original_path"
  export PATH
}

test_supported_platform_matrix
test_unsupported_platform_matrix
test_package_installation
test_browser_selection
test_unsupported_stops_before_side_effects

printf '1..%d\n' "$test_count"
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
