#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: guest-control.sh start-compositor|env|capture|start-dock|stop-dock [png-path]" >&2
  exit 2
}

cmd=${1:-}
[[ -n "$cmd" ]] || usage

name=${SMARTDOCK_SESSION_NAME:?SMARTDOCK_SESSION_NAME is required}
candidate=${SMARTDOCK_CANDIDATE:-/home/admin/smartdock-candidate}
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/smartdock/dev-sessions/${name}"
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
ready="${state_root}/ready.json"
config="${state_root}/guest-hyprland.lua"
log="${state_root}/hyprland.log"
pidfile="${state_root}/hyprland.pid"
src_lua="${candidate}/tests/runtime/dev-session/guest-hyprland.lua"
hypr_wrapper="${state_root}/run-hyprland.sh"

load_ready() {
  python3 - "$ready" <<'PY'
import json, os, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
for key in ("wayland_display", "hyprland_instance_signature", "output"):
    if not data.get(key):
        raise SystemExit(f"missing {key} in {path}")
runtime = data.get("xdg_runtime_dir") or os.environ.get("XDG_RUNTIME_DIR", "")
print(data["wayland_display"])
print(data["hyprland_instance_signature"])
print(data["output"])
print(runtime)
PY
}

finish_ready() {
  display=$(python3 -c "import json; print(json.load(open('$ready'))['wayland_display'])")
  sig=$(python3 -c "import json; print(json.load(open('$ready'))['hyprland_instance_signature'])")
  export WAYLAND_DISPLAY="$display"
  export HYPRLAND_INSTANCE_SIGNATURE="$sig"
  export XDG_RUNTIME_DIR="$runtime_dir"
  monitors=$(hyprctl -j monitors)
  MONITORS_JSON="$monitors" python3 - "$ready" "$runtime_dir" <<'PY'
import json, os, sys
from pathlib import Path
ready_path = Path(sys.argv[1])
runtime_dir = sys.argv[2]
data = json.loads(ready_path.read_text(encoding="utf-8"))
monitors = json.loads(os.environ["MONITORS_JSON"])
if not isinstance(monitors, list) or len(monitors) != 1:
    raise SystemExit(f"expected exactly one monitor, got {monitors!r}")
output = monitors[0].get("name")
if not output:
    raise SystemExit("monitor has no name")
data["output"] = output
data["xdg_runtime_dir"] = runtime_dir
ready_path.write_text(json.dumps(data, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(data, sort_keys=True))
PY
}

compositor_running() {
  [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

owned_lock_instance() {
  python3 - "$config" "$runtime_dir" <<'PY'
import os, sys
from pathlib import Path
config = sys.argv[1]
runtime_dir = Path(sys.argv[2])
root = runtime_dir / "hypr"
if not root.is_dir():
    raise SystemExit(0)
for inst in root.iterdir():
    lock = inst / "hyprland.lock"
    if not lock.is_file():
        continue
    lines = lock.read_text(encoding="utf-8").splitlines()
    if not lines:
        continue
    try:
        pid = int(lines[0])
    except ValueError:
        continue
    cmdline = Path(f"/proc/{pid}/cmdline")
    if not cmdline.is_file():
        continue
    raw = cmdline.read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
    if config not in raw:
        continue
    display = lines[1] if len(lines) > 1 else ""
    print(pid)
    print(display)
    print(inst.name)
    break
PY
}

start_compositor() {
  mkdir -p "$state_root"
  chmod 700 "$state_root"
  mkdir -p "$runtime_dir"
  chmod 700 "$runtime_dir"
  cp "$src_lua" "$config"
  sudo -n usermod -aG seat,video "$(id -un)" >/dev/null 2>&1 || true
  sudo -n systemctl start seatd >/dev/null 2>&1 || true
  sudo -n chmod 770 /run/seatd.sock >/dev/null 2>&1 || true
  sudo -n chgrp seat /run/seatd.sock >/dev/null 2>&1 || true
  Hyprland --verify-config --config "$config" >/dev/null

  lock_info=$(owned_lock_instance || true)
  if [[ -n "$lock_info" ]]; then
    mapfile -t lock_fields < <(printf '%s\n' "$lock_info")
    echo "${lock_fields[0]}" >"$pidfile"
    python3 - "$ready" "${lock_fields[1]}" "${lock_fields[2]}" <<'PY'
import json, sys
from pathlib import Path
ready = Path(sys.argv[1])
ready.write_text(json.dumps({
    "wayland_display": sys.argv[2],
    "hyprland_instance_signature": sys.argv[3],
}) + "\n", encoding="utf-8")
PY
  fi

  if compositor_running && [[ -f "$ready" ]]; then
    finish_ready
    return
  fi

  if compositor_running; then
    owned_pid=$(cat "$pidfile")
    pkill -TERM -P "$owned_pid" 2>/dev/null || true
    kill -TERM "$owned_pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      compositor_running || break
      sleep 0.1
    done
  fi

  rm -f "$ready"
  cat > "$hypr_wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
unset WAYLAND_DISPLAY
unset DISPLAY
export LIBSEAT_BACKEND=seatd
export SMARTDOCK_GUEST_READY=$(printf '%q' "$ready")
export XDG_RUNTIME_DIR=$(printf '%q' "$runtime_dir")
exec Hyprland --config $(printf '%q' "$config")
EOF
  chmod 700 "$hypr_wrapper"

  if compositor_running; then
    echo "owned compositor pid $(cat "$pidfile") is running without readiness JSON" >&2
    exit 1
  fi

  if id -nG | grep -qw seat; then
    nohup "$hypr_wrapper" >"$log" 2>&1 &
  else
    nohup sudo -n -u "$(id -un)" -g seat "$hypr_wrapper" >"$log" 2>&1 &
  fi
  echo $! >"$pidfile"

  for _ in $(seq 1 30); do
    if [[ -f "$ready" ]]; then
      break
    fi
    if ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      echo "Hyprland exited before readiness" >&2
      tail -n 80 "$log" >&2 || true
      exit 1
    fi
    sleep 1
  done
  [[ -f "$ready" ]] || {
    echo "guest compositor readiness JSON was not written" >&2
    tail -n 80 "$log" >&2 || true
    exit 1
  }
  finish_ready
}

print_env() {
  cat "$ready"
}

capture() {
  png=${2:?png path required}
  mapfile -t ready_fields < <(load_ready)
  export WAYLAND_DISPLAY="${ready_fields[0]}"
  export HYPRLAND_INSTANCE_SIGNATURE="${ready_fields[1]}"
  output=${ready_fields[2]}
  export XDG_RUNTIME_DIR="${ready_fields[3]:-$runtime_dir}"
  timeout 10s grim -o "$output" "$png"
}

start_dock() {
  mapfile -t ready_fields < <(load_ready)
  export WAYLAND_DISPLAY="${ready_fields[0]}"
  export HYPRLAND_INSTANCE_SIGNATURE="${ready_fields[1]}"
  export XDG_RUNTIME_DIR="${ready_fields[3]:-$runtime_dir}"
  omarchy_path="${OMARCHY_PATH:-$HOME/smartdock-omarchy-test}"
  mode="${SMARTDOCK_SESSION_MODE:-standalone}"
  if [[ ! -d "$omarchy_path/shell/Commons" || ! -d "$omarchy_path/shell/Ui" ]]; then
    echo "missing Omarchy qs.Commons/Ui test assets at $omarchy_path/shell" >&2
    exit 1
  fi
  mkdir -p "$HOME/.config/smartdock"
  dest="$HOME/.config/smartdock/dock.json"
  src="$candidate/config/dock.json"
  if [[ ! -f "$dest" ]]; then
    cp "$src" "$dest"
    chmod 600 "$dest"
  fi
  export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
  export SMARTDOCK_CONFIG="$dest"
  export OMARCHY_PATH="$omarchy_path"
  import_root="${XDG_CACHE_HOME:-$HOME/.cache}/smartdock/qml-imports"
  mkdir -p "$import_root"
  rm -f "$import_root/qs"
  ln -s "$omarchy_path/shell" "$import_root/qs"
  export QML2_IMPORT_PATH="$import_root${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
  dock_log="$state_root/dock.log"
  dock_pidfile="$state_root/dock.pid"
  mkdir -p "$state_root"

  owned_dock() {
    local pid=$1
    local cmdline
    cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
    [[ "$cmdline" == *"$candidate"* || "$cmdline" == *"$omarchy_path/shell"* ]]
  }

  if [[ -f "$dock_pidfile" ]]; then
    old_pid=$(cat "$dock_pidfile")
    if kill -0 "$old_pid" 2>/dev/null && owned_dock "$old_pid"; then
      python3 -c "import json; print(json.dumps({'pid': int('$old_pid'), 'config_path': '$dest', 'reused': True}))"
      return
    fi
    rm -f "$dock_pidfile"
  fi

  if [[ "$mode" == plugin ]]; then
    if [[ ! -f "$omarchy_path/shell/shell.qml" ]]; then
      echo "missing Omarchy plugin host at $omarchy_path/shell/shell.qml" >&2
      exit 1
    fi
    if [[ ! -e "$HOME/.config/omarchy/plugins/io.github.fernandodamaso.smartdock/Overlay.qml" ]]; then
      echo "missing guest SmartDock plugin Overlay.qml" >&2
      exit 1
    fi
    nohup qs -p "$omarchy_path/shell" >"$dock_log" 2>&1 &
  else
    nohup "$candidate/scripts/run" >"$dock_log" 2>&1 &
  fi
  echo $! >"$dock_pidfile"
  pid=$(cat "$dock_pidfile")
  for _ in $(seq 1 45); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "guest dock exited before qs list" >&2
      tail -n 120 "$dock_log" >&2 || true
      exit 1
    fi
    list_json=$(qs list --all --json 2>/dev/null || true)
    if QS_LIST_JSON="$list_json" python3 -c '
import json, os, sys
raw = os.environ.get("QS_LIST_JSON", "").strip()
if raw in ("", "No running instances."):
    raise SystemExit(1)
data = json.loads(raw)
pid = int(sys.argv[1])
raise SystemExit(0 if any(isinstance(item, dict) and item.get("pid") == pid for item in data) else 1)
' "$pid"; then
      python3 -c "import json; print(json.dumps({'pid': int('$pid'), 'config_path': '$dest', 'reused': False, 'mode': '$mode'}))"
      return
    fi
    sleep 1
  done
  echo "guest dock pid $pid never appeared in qs list --all --json" >&2
  tail -n 120 "$dock_log" >&2 || true
  exit 1
}

stop_dock() {
  dock_pidfile="$state_root/dock.pid"
  omarchy_path="${OMARCHY_PATH:-$HOME/smartdock-omarchy-test}"
  [[ -f "$dock_pidfile" ]] || return 0
  pid=$(cat "$dock_pidfile")
  if kill -0 "$pid" 2>/dev/null; then
    cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
    if [[ "$cmdline" == *"$candidate"* || "$cmdline" == *"$omarchy_path/shell"* ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
  fi
  rm -f "$dock_pidfile"
}

case "$cmd" in
  start-compositor)
    start_compositor
    ;;
  env)
    print_env
    ;;
  capture)
    capture "$@"
    ;;
  start-dock)
    start_dock
    ;;
  stop-dock)
    stop_dock
    ;;
  *)
    usage
    ;;
esac
