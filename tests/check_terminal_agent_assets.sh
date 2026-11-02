#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

data_home="$test_root/data"
config_home="$test_root/config"
state_home="$test_root/state"
bin_home="$test_root/bin"
home_dir="$test_root/home"
no_qs_bin="$test_root/no-qs"
fake_qs_bin="$test_root/fake-bin"
mkdir -p "$data_home" "$config_home" "$bin_home" "$home_dir" "$no_qs_bin" "$fake_qs_bin"

fail() {
  echo "check_terminal_agent_assets: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_missing() {
  [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

assert_contains() {
  local file="$1"
  local needle="$2"
  rg -F -- "$needle" "$file" >/dev/null || fail "missing '$needle' in $file"
}

assert_same_file() {
  cmp -s -- "$1" "$2" || fail "files differ: $1 and $2"
}

ids=(
  smartdock-agent-pi
  smartdock-agent-oh-my-pi
  smartdock-agent-command-code
  smartdock-agent-cursor
  smartdock-agent-claude-code
  smartdock-agent-kilo-code
  smartdock-agent-cline
  smartdock-agent-herdr
)

commands=(pi omp commandcode cursor-agent claude kilo cline herdr)
extensions=(png svg svg svg svg svg svg svg)
window_classes=(
  io.github.fernandodamaso.smartdock.agent.pi
  io.github.fernandodamaso.smartdock.agent.oh-my-pi
  io.github.fernandodamaso.smartdock.agent.command-code
  io.github.fernandodamaso.smartdock.agent.cursor
  io.github.fernandodamaso.smartdock.agent.claude-code
  io.github.fernandodamaso.smartdock.agent.kilo-code
  io.github.fernandodamaso.smartdock.agent.cline
  io.github.fernandodamaso.smartdock.agent.herdr
)

desktop_dir="$data_home/applications"
svg_dir="$data_home/icons/hicolor/scalable/apps"
raster_dir="$data_home/icons/hicolor/256x256/apps"

export HOME="$home_dir"
export XDG_DATA_HOME="$data_home"
export XDG_CONFIG_HOME="$config_home"
export XDG_STATE_HOME="$state_home"
export XDG_CACHE_HOME="$test_root/cache"
export XDG_BIN_HOME="$bin_home"
unset DOCKRAIL_CONFIG SMARTDOCK_CONFIG DOCKRAIL_MIGRATION_FAIL_AFTER

config_file="$config_home/smartdock/dock.json"
install -d "$(dirname -- "$config_file")"
printf '%s\n' '{"sentinel":"keep-me"}' >"$config_file"

# Deterministic agent detection: both no-qs and fake-qs PATHs expose eight agents.
for agent in "${commands[@]}"; do
  printf '#!/bin/sh\nexit 0\n' >"$no_qs_bin/$agent"
  chmod 0755 "$no_qs_bin/$agent"
  cp -- "$no_qs_bin/$agent" "$fake_qs_bin/$agent"
done
PATH="$no_qs_bin:/usr/bin:/bin" bash "$repo_dir/install.sh" --agent-assets-only \
  || fail "asset-only install failed without qs"

assert_file "$state_home/dockrail/terminal-agent-launchers.json"

for i in "${!ids[@]}"; do
  id="${ids[$i]}"
  command_name="${commands[$i]}"
  window_class="${window_classes[$i]}"
  desktop_file="$desktop_dir/$id.desktop"
  assert_file "$desktop_file"
  assert_contains "$desktop_file" 'Type=Application'
  assert_contains "$desktop_file" 'Terminal=false'
  assert_contains "$desktop_file" "StartupWMClass=$window_class"
  assert_contains "$desktop_file" "Icon=$id"
  assert_contains "$desktop_file" "Exec=ghostty --gtk-single-instance=false --class=$window_class -e $command_name"
  assert_contains "$desktop_file" 'Categories=Development;'
  if [[ "${extensions[$i]}" == svg ]]; then
    assert_file "$svg_dir/$id.svg"
  else
    assert_file "$raster_dir/$id.${extensions[$i]}"
  fi
done

assert_missing "$data_home/dockrail"
assert_missing "$data_home/smartdock"
assert_missing "$config_home/autostart/smartdock.desktop"
assert_missing "$bin_home/dockrail"
assert_missing "$bin_home/smartdock"
assert_same_file "$config_file" <(printf '%s\n' '{"sentinel":"keep-me"}')

PATH="$no_qs_bin:/usr/bin:/bin" bash "$repo_dir/uninstall.sh" --agent-assets-only \
  || fail "asset-only uninstall failed without qs"

for i in "${!ids[@]}"; do
  id="${ids[$i]}"
  assert_missing "$desktop_dir/$id.desktop"
  if [[ "${extensions[$i]}" == svg ]]; then
    assert_missing "$svg_dir/$id.svg"
  else
    assert_missing "$raster_dir/$id.${extensions[$i]}"
  fi
done
assert_file "$config_file"
assert_missing "$data_home/dockrail"
assert_missing "$data_home/smartdock"
assert_missing "$config_home/autostart/smartdock.desktop"
assert_missing "$bin_home/dockrail"
assert_missing "$bin_home/smartdock"

printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_qs_bin/qs"
chmod 0755 "$fake_qs_bin/qs"

PATH="$fake_qs_bin:/usr/bin:/bin" bash "$repo_dir/install.sh" \
  || fail "full install failed with fake qs"

canonical_config="$config_home/dockrail/dock.json"
assert_file "$data_home/dockrail/shell.qml"
assert_file "$data_home/dockrail/assets/lucide/terminal.svg"
assert_file "$data_home/dockrail/assets/terminal-agents/ATTRIBUTIONS.md"
diff -qr -- "$repo_dir/assets" "$data_home/dockrail/assets" \
  || fail "installed assets directory differs from bundled assets"
assert_file "$canonical_config"
assert_same_file "$canonical_config" <(printf '%s\n' '{"sentinel":"keep-me"}')
[[ -L "$config_home/smartdock" ]] || fail "legacy config root must become a compatibility alias"
[[ "$(readlink -f -- "$config_home/smartdock")" == "$(readlink -f -- "$config_home/dockrail")" ]] \
  || fail "legacy config alias must target canonical Dockrail config"
assert_file "$config_home/autostart/smartdock.desktop"
assert_file "$bin_home/dockrail"
assert_file "$bin_home/smartdock"

printf '%s\n' 'stale installed file' >"$data_home/dockrail/components/Dock.qml"
PATH="$fake_qs_bin:/usr/bin:/bin" "$bin_home/smartdock" update \
  || fail "installed update from source checkout failed"
assert_same_file "$repo_dir/components/Dock.qml" \
  "$data_home/dockrail/components/Dock.qml"
assert_file "$data_home/dockrail/assets/terminal-agents/ATTRIBUTIONS.md"

PATH="$no_qs_bin:/usr/bin:/bin" bash "$repo_dir/uninstall.sh" \
  --agent-assets-only \
  || fail "asset-only uninstall after full install failed without qs"
assert_file "$data_home/dockrail/shell.qml"
assert_file "$config_home/autostart/smartdock.desktop"
assert_file "$bin_home/dockrail"
assert_file "$bin_home/smartdock"
assert_file "$canonical_config"
for i in "${!ids[@]}"; do
  id="${ids[$i]}"
  assert_missing "$desktop_dir/$id.desktop"
  if [[ "${extensions[$i]}" == svg ]]; then
    assert_missing "$svg_dir/$id.svg"
  else
    assert_missing "$raster_dir/$id.${extensions[$i]}"
  fi
done

PATH="$no_qs_bin:/usr/bin:/bin" bash "$repo_dir/uninstall.sh" \
  || fail "full uninstall failed without qs"
assert_missing "$data_home/dockrail"
assert_missing "$config_home/autostart/smartdock.desktop"
assert_missing "$bin_home/dockrail"
assert_missing "$bin_home/smartdock"
assert_file "$canonical_config"
assert_file "$config_file"

echo "check_terminal_agent_assets: PASS"
