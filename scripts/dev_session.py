#!/usr/bin/env python3
"""Foreground KVM SmartDock development sessions (host supervisor)."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

NAME_RE = re.compile(r"[a-z][a-z0-9-]{0,31}")
SOURCE_REQUIRED = (
    "shell.qml",
    "Overlay.qml",
    "scripts/run",
    "scripts/smartdock",
    "config/dock.json",
)
OVMF_CODE = Path("/usr/share/edk2/x64/OVMF_CODE.4m.fd")
OVMF_VARS_TEMPLATE = Path("/usr/share/edk2/x64/OVMF_VARS.4m.fd")
HOST_TOOLS = (
    "qemu-system-x86_64",
    "qemu-img",
    "cloud-localds",
    "ssh-keygen",
    "ssh",
    "scp",
    "hyprctl",
)
PORT_MIN = 22000
PORT_MAX = 22999
ACTIVE_STATES = {"starting", "ready", "stopping"}
RECORD_FIELDS = (
    "name",
    "state",
    "source",
    "mode",
    "source_digest",
    "base_image",
    "port",
    "qemu_pid",
    "qemu_start_ticks",
    "qemu_pgid",
    "qemu_window_address",
    "guest_display",
    "guest_signature",
    "guest_output",
    "host_pid",
    "config_path",
    "evidence_path",
    "error",
)


def validate_name(value: str) -> str:
    if not NAME_RE.fullmatch(value or ""):
        raise ValueError(f"invalid session name: {value!r}")
    return value


def default_state_root() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / (
        "smartdock/dev-sessions"
    )


def default_runtime_root() -> Path:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        raise ValueError("XDG_RUNTIME_DIR is required")
    return Path(runtime) / "smartdock-dev"


def session_dir(name: str, state_root: Path | None = None) -> Path:
    name = validate_name(name)
    root = state_root if state_root is not None else default_state_root()
    return (root / name).resolve()


def process_identity(pid: int) -> dict | None:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        return None
    close = raw.rfind(")")
    if close < 0:
        return None
    fields = raw[close + 2 :].split()
    if len(fields) < 20:
        return None
    try:
        start_ticks = int(fields[19])  # field 22 overall
        pgid = os.getpgid(pid)
    except (ValueError, ProcessLookupError, PermissionError):
        return None
    return {"pid": int(pid), "start_ticks": start_ticks, "pgid": pgid}


@contextlib.contextmanager
def _flock(path: Path, *, shared: bool = False):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("a+", encoding="utf-8") as lock:
        os.chmod(path, 0o600)
        fcntl.flock(lock.fileno(), fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
        try:
            yield lock
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


@contextlib.contextmanager
def _port_registry_lock(runtime_root: Path):
    runtime_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(runtime_root, 0o700)
    with _flock(runtime_root / "registry.lock"):
        yield


def _port_available(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def _reservation_path(runtime_root: Path, port: int) -> Path:
    return runtime_root / "ports" / f"{port}.json"


def _reserve_port_locked(runtime_root: Path, name: str) -> int:
    ports = runtime_root / "ports"
    ports.mkdir(mode=0o700, parents=True, exist_ok=True)
    for path in ports.glob("*.json"):
        try:
            reservation = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if reservation.get("name") == name:
            raise ValueError(f"session {name!r} already has a reserved port")

    for port in range(PORT_MIN, PORT_MAX + 1):
        path = _reservation_path(runtime_root, port)
        if path.exists() or not _port_available(port):
            continue
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        with os.fdopen(fd, "w", encoding="utf-8") as reservation:
            json.dump({"name": name, "port": port}, reservation, sort_keys=True)
            reservation.write("\n")
        return port
    raise ValueError(f"no free loopback port in {PORT_MIN}..{PORT_MAX}")


def reserve_port(runtime_root: Path, name: str) -> int:
    """Atomically reserve one currently free loopback port for NAME."""
    name = validate_name(name)
    runtime_root = runtime_root.expanduser().resolve()
    with _port_registry_lock(runtime_root):
        return _reserve_port_locked(runtime_root, name)


def _release_port(runtime_root: Path, name: str, port: int | None) -> None:
    if port is None:
        return
    with _port_registry_lock(runtime_root):
        path = _reservation_path(runtime_root, int(port))
        try:
            reservation = json.loads(path.read_text(encoding="utf-8"))
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            return
        if reservation.get("name") == name:
            path.unlink(missing_ok=True)


def _record_path(name: str) -> Path:
    return session_dir(name) / "record.json"


def _validate_record(name: str, value: object) -> dict:
    if not isinstance(value, dict):
        raise ValueError(f"malformed record for {name!r}: expected JSON object")
    if value.get("name") != name or not isinstance(value.get("state"), str):
        raise ValueError(f"malformed record for {name!r}: invalid name or state")
    return value


def _read_record_unlocked(name: str) -> dict:
    path = _record_path(name)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"no session record for {name!r}") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"malformed record for {name!r}: {exc}") from exc
    return _validate_record(name, value)


def read_record(name: str) -> dict:
    """Read and validate NAME's record without selecting any other session."""
    name = validate_name(name)
    session = session_dir(name)
    if not session.is_dir():
        raise ValueError(f"no session record for {name!r}")
    with _flock(session / "record.lock", shared=True):
        return _read_record_unlocked(name)


def _write_record(record: dict) -> None:
    name = validate_name(record.get("name", ""))
    _validate_record(name, record)
    session = session_dir(name)
    session.mkdir(mode=0o700, parents=True, exist_ok=True)
    with _flock(session / "record.lock"):
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=session,
            prefix=".record.",
            delete=False,
        ) as temp:
            json.dump(record, temp, indent=2, sort_keys=True)
            temp.write("\n")
            temp.flush()
            os.fsync(temp.fileno())
            temp_path = Path(temp.name)
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, session / "record.json")


def owned_process(record: dict) -> bool:
    """Return whether PID, /proc start ticks and process group all still match."""
    try:
        expected = {
            "pid": int(record["qemu_pid"]),
            "start_ticks": int(record["qemu_start_ticks"]),
            "pgid": int(record["qemu_pgid"]),
        }
    except (KeyError, TypeError, ValueError):
        return False
    current = process_identity(expected["pid"])
    return current == expected


def resolve_existing_dir(path: Path, label: str) -> Path:
    resolved = path.expanduser()
    if not resolved.is_absolute():
        raise ValueError(f"{label} must be an absolute path: {path}")
    resolved = resolved.resolve()
    if not resolved.is_dir():
        raise ValueError(f"{label} is not an existing directory: {resolved}")
    return resolved


def resolve_existing_file(path: Path, label: str) -> Path:
    resolved = path.expanduser()
    if not resolved.is_absolute():
        raise ValueError(f"{label} must be an absolute path: {path}")
    resolved = resolved.resolve()
    if not resolved.is_file():
        raise ValueError(f"{label} is not an existing file: {resolved}")
    return resolved


def validate_source(source: Path) -> Path:
    source = resolve_existing_dir(source, "source")
    missing = [rel for rel in SOURCE_REQUIRED if not (source / rel).exists()]
    if missing:
        raise ValueError(f"source missing required paths: {', '.join(missing)}")
    return source


def require_host_tools() -> None:
    if not Path("/dev/kvm").exists():
        raise ValueError("/dev/kvm is required")
    missing = [tool for tool in HOST_TOOLS if shutil.which(tool) is None]
    if missing:
        raise ValueError(f"missing host tools: {', '.join(missing)}")
    if not OVMF_CODE.is_file() or not OVMF_VARS_TEMPLATE.is_file():
        raise ValueError("edk2 OVMF firmware files are required under /usr/share/edk2/x64")


def qemu_argv(paths: dict, port: int) -> list[str]:
    overlay = Path(paths["overlay"])
    vars_fd = Path(paths["vars"])
    seed = Path(paths["seed"])
    name = paths.get("name", "smartdock-dev-session")
    return [
        "qemu-system-x86_64",
        "-name",
        f"SmartDock {name},process=smartdock-dev-{name}",
        "-machine",
        "q35,accel=kvm,usb=off",
        "-cpu",
        "host",
        "-smp",
        "4",
        "-m",
        "4096",
        "-drive",
        f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
        "-drive",
        f"if=pflash,format=raw,file={vars_fd}",
        "-drive",
        f"file={overlay},if=virtio,format=qcow2,discard=unmap",
        "-drive",
        f"file={seed},media=cdrom,if=virtio,readonly=on",
        "-device",
        "virtio-vga",
        "-display",
        "gtk,gl=off,window-close=on",
        "-netdev",
        f"user,id=net0,hostfwd=tcp:127.0.0.1:{int(port)}-:22",
        "-device",
        "virtio-net-pci,netdev=net0",
        "-device",
        "virtio-keyboard-pci",
        "-device",
        "virtio-mouse-pci",
    ]


def redact_argv(argv: list[str]) -> list[str]:
    redacted = []
    for item in argv:
        if "id_ed25519" in item or item.endswith(".pub"):
            redacted.append("<redacted-key-path>")
        else:
            redacted.append(item)
    return redacted


def _write_cloud_init(session: Path, pub_key: str) -> tuple[Path, Path]:
    cidata = session / "cidata"
    cidata.mkdir(mode=0o700, parents=True, exist_ok=True)
    user_data = cidata / "user-data"
    meta_data = cidata / "meta-data"
    user_data.write_text(
        "\n".join(
            [
                "#cloud-config",
                "growpart:",
                "  mode: auto",
                "  devices: ['/']",
                "  ignore_growroot_disabled: false",
                "resize_rootfs: true",
                "users:",
                "  - name: admin",
                "    sudo: ALL=(ALL) NOPASSWD:ALL",
                "    shell: /bin/bash",
                "    ssh_authorized_keys:",
                f"      - {pub_key.rstrip()}",
                "ssh_pwauth: false",
                "package_update: false",
                "",
            ]
        ),
        encoding="utf-8",
    )
    meta_data.write_text(
        f"instance-id: smartdock-{session.name}\nlocal-hostname: smartdock-{session.name}\n",
        encoding="utf-8",
    )
    return user_data, meta_data


def prepare_private_inputs(
    name: str,
    *,
    source: Path,
    base_image: Path,
    state_root: Path | None = None,
    runtime_root: Path | None = None,
) -> dict:
    """Reserve NAME and create private overlay/vars/seed/SSH inputs without starting QEMU."""
    del runtime_root  # reserved for later tasks' port registry
    name = validate_name(name)
    require_host_tools()
    source = validate_source(source)
    base_image = resolve_existing_file(base_image, "base-image")

    root = state_root if state_root is not None else default_state_root()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    session = root / name
    if session.exists() or session.is_symlink():
        raise ValueError(f"session directory already exists: {session}")

    session.mkdir(mode=0o700)
    try:
        overlay = session / "overlay.qcow2"
        vars_fd = session / "vars.fd"
        seed = session / "seed.iso"
        ssh_key = session / "id_ed25519"
        ssh_pub = session / "id_ed25519.pub"
        known_hosts = session / "known_hosts"

        subprocess.run(
            [
                "qemu-img",
                "create",
                "-f",
                "qcow2",
                "-F",
                "qcow2",
                "-b",
                str(base_image),
                str(overlay),
                "40G",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        shutil.copyfile(OVMF_VARS_TEMPLATE, vars_fd)
        os.chmod(vars_fd, 0o600)

        subprocess.run(
            [
                "ssh-keygen",
                "-t",
                "ed25519",
                "-N",
                "",
                "-f",
                str(ssh_key),
                "-C",
                f"smartdock-dev-{name}",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        os.chmod(ssh_key, 0o600)
        pub_key = ssh_pub.read_text(encoding="utf-8")
        user_data, meta_data = _write_cloud_init(session, pub_key)
        subprocess.run(
            ["cloud-localds", str(seed), str(user_data), str(meta_data)],
            check=True,
            capture_output=True,
            text=True,
        )
        known_hosts.write_text("", encoding="utf-8")
        os.chmod(known_hosts, 0o600)

        paths = {
            "name": name,
            "session": session,
            "source": source,
            "base_image": base_image,
            "overlay": overlay,
            "vars": vars_fd,
            "seed": seed,
            "ssh_key": ssh_key,
            "ssh_pub": ssh_pub,
            "known_hosts": known_hosts,
            "evidence": session / "evidence",
        }
        paths["evidence"].mkdir(mode=0o700, exist_ok=True)
        (session / "qemu.argv").write_text(
            "\n".join(redact_argv(qemu_argv(paths, 22000))) + "\n",
            encoding="utf-8",
        )
        return paths
    except Exception:
        shutil.rmtree(session, ignore_errors=True)
        raise


def _host_command_json(command: str) -> object:
    result = subprocess.run(
        ["hyprctl", "-j", command],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def _settings_digest() -> str:
    path = Path.home() / ".config/smartdock/dock.json"
    if not path.is_file():
        return "missing"
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _capture_host_state(evidence: Path, tag: str) -> dict:
    state = {
        "active_workspace": _host_command_json("activeworkspace"),
        "active_window": _host_command_json("activewindow"),
        "cursor": subprocess.run(
            ["hyprctl", "cursorpos"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip(),
        "production_settings_sha256": _settings_digest(),
    }
    (evidence / f"host-{tag}.json").write_text(
        json.dumps(state, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return state


def _lua_string(value: str) -> str:
    return json.dumps(value)


def _launch_rule(name: str, workspace: str) -> None:
    title = f"^QEMU \\(SmartDock {re.escape(name)}\\)$"
    rule_name = f"smartdock-dev-{name}"
    expression = (
        "local r=hl.window_rule({ "
        f"name = {_lua_string(rule_name)}, "
        f"match = {{ title = {_lua_string(title)} }}, "
        f"workspace = {_lua_string(workspace + ' silent')}, "
        "no_initial_focus = true }); "
        "return r and r:is_enabled()"
    )
    result = subprocess.run(
        ["hyprctl", "repl", expression],
        check=True,
        capture_output=True,
        text=True,
    )
    if result.stdout.strip() != "true":
        raise RuntimeError(f"failed to establish QEMU launch rule: {result.stdout.strip()}")


def _disable_launch_rule(name: str) -> None:
    rule_name = f"smartdock-dev-{name}"
    title = f"^QEMU \\(SmartDock {re.escape(name)}\\)$"
    expression = (
        "local r=hl.window_rule({ "
        f"name = {_lua_string(rule_name)}, enabled = false, "
        f"match = {{ title = {_lua_string(title)} }} }}); "
        "return r and r:is_enabled()"
    )
    subprocess.run(
        ["hyprctl", "repl", expression],
        check=False,
        capture_output=True,
        text=True,
    )


def _workspace_matches(client: dict, workspace: str) -> bool:
    current = client.get("workspace") or {}
    return str(current.get("name")) == workspace or str(current.get("id")) == workspace


def _wait_for_owned_window(pid: int, timeout: float = 20.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        clients = _host_command_json("clients")
        matches = [client for client in clients if client.get("pid") == pid]
        if len(matches) > 1:
            raise RuntimeError(f"QEMU PID {pid} owns {len(matches)} host windows; expected one")
        if len(matches) == 1:
            return matches[0]
        time.sleep(0.25)
    raise RuntimeError(f"no unique host window found for owned QEMU PID {pid}")


def _move_owned_window(pid: int, address: str, workspace: str) -> None:
    expression = (
        "local w=nil; "
        "for _,candidate in ipairs(hl.get_windows()) do "
        f"if candidate.pid == {pid} and candidate.address == {_lua_string(address)} "
        "then w=candidate end end; "
        "if not w then error('owned QEMU window disappeared') end; "
        "hl.dispatch(hl.dsp.window.move({ "
        f"workspace = {_lua_string(workspace)}, follow = false, window = w }})); "
        "return w.address"
    )
    result = subprocess.run(
        ["hyprctl", "repl", expression],
        check=True,
        capture_output=True,
        text=True,
    )
    if result.stdout.strip() != address:
        raise RuntimeError("Hyprland did not return the exact owned QEMU address")


def _place_owned_window(pid: int, workspace: str) -> dict:
    client = _wait_for_owned_window(pid)
    address = client.get("address")
    if not isinstance(address, str) or not address:
        raise RuntimeError("owned QEMU window has no address")
    if not _workspace_matches(client, workspace):
        _move_owned_window(pid, address, workspace)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            matches = [
                item
                for item in _host_command_json("clients")
                if item.get("pid") == pid and item.get("address") == address
            ]
            if len(matches) == 1 and _workspace_matches(matches[0], workspace):
                return matches[0]
            time.sleep(0.1)
        raise RuntimeError(
            f"owned QEMU window {address} did not reach workspace {workspace!r}"
        )
    return client


def _process_socket_inodes(pid: int) -> set[str]:
    inodes = set()
    try:
        entries = Path(f"/proc/{pid}/fd").iterdir()
        for entry in entries:
            try:
                target = os.readlink(entry)
            except (FileNotFoundError, PermissionError):
                continue
            match = re.fullmatch(r"socket:\[(\d+)\]", target)
            if match:
                inodes.add(match.group(1))
    except (FileNotFoundError, PermissionError):
        pass
    return inodes


def _owned_process_listens(record: dict) -> bool:
    if not owned_process(record):
        return False
    inodes = _process_socket_inodes(int(record["qemu_pid"]))
    if not inodes:
        return False
    port_hex = f"{int(record['port']):04X}"
    for table in (Path("/proc/net/tcp"), Path("/proc/net/tcp6")):
        try:
            lines = table.read_text(encoding="utf-8").splitlines()[1:]
        except (FileNotFoundError, PermissionError):
            continue
        for line in lines:
            fields = line.split()
            if (
                len(fields) > 9
                and fields[1].rsplit(":", 1)[-1] == port_hex
                and fields[3] == "0A"
                and fields[9] in inodes
            ):
                return True
    return False


def _wait_for_owned_port(record: dict, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not owned_process(record):
            raise RuntimeError("QEMU exited before binding its reserved SSH port")
        if _owned_process_listens(record):
            return
        time.sleep(0.1)
    raise RuntimeError("owned QEMU did not bind its reserved SSH port")


def _ssh_argv(record: dict, remote_command: str) -> list[str]:
    session = session_dir(record["name"])
    return [
        "ssh",
        "-i",
        str(session / "id_ed25519"),
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        f"UserKnownHostsFile={session / 'known_hosts'}",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ConnectTimeout=5",
        "-p",
        str(record["port"]),
        "admin@127.0.0.1",
        remote_command,
    ]


def _run_ssh(record: dict, command: str, timeout: float) -> subprocess.CompletedProcess:
    return subprocess.run(
        _ssh_argv(record, command),
        check=False,
        capture_output=True,
        text=True,
        timeout=max(1, timeout),
    )


def _stderr_snippet(stderr: str | None, limit: int = 400) -> str:
    text = " ".join((stderr or "").split())
    if len(text) > limit:
        return text[: limit - 3] + "..."
    return text


def _write_ssh_progress(
    evidence: Path, attempt: int, result: subprocess.CompletedProcess
) -> None:
    payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "attempt": int(attempt),
        "last_ssh_returncode": int(result.returncode),
        "last_ssh_stderr": _stderr_snippet(getattr(result, "stderr", "")),
    }
    path = evidence / "progress.json"
    tmp = evidence / ".progress.json.tmp"
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def _wait_for_guest_setup(record: dict, evidence: Path) -> None:
    deadline = time.monotonic() + 600
    attempts = []
    attempt = 0
    while time.monotonic() < deadline:
        result = _run_ssh(record, "true", min(10, deadline - time.monotonic()))
        attempt += 1
        attempts.append(
            {
                "returncode": result.returncode,
                "stderr": (result.stderr or "").strip(),
                "time": time.time(),
            }
        )
        _write_ssh_progress(evidence, attempt, result)
        if result.returncode == 0:
            break
        time.sleep(min(2, max(0, deadline - time.monotonic())))
    else:
        raise RuntimeError("SSH did not become ready within 10 minutes")
    (evidence / "ssh-attempts.json").write_text(
        json.dumps(attempts, indent=2) + "\n",
        encoding="utf-8",
    )

    cloud_init = _run_ssh(
        record,
        "cloud-init status --wait",
        deadline - time.monotonic(),
    )
    (evidence / "cloud-init.log").write_text(
        cloud_init.stdout + cloud_init.stderr,
        encoding="utf-8",
    )
    if cloud_init.returncode != 0:
        raise RuntimeError(f"cloud-init failed with exit code {cloud_init.returncode}")

    setup_command = r"""
set -euo pipefail
packages=()
command -v Hyprland >/dev/null || packages+=(hyprland)
command -v qs >/dev/null || packages+=(quickshell)
command -v grim >/dev/null || packages+=(grim)
command -v wtype >/dev/null || packages+=(wtype)
command -v python3 >/dev/null || packages+=(python)
command -v seatd >/dev/null || packages+=(seatd)
if ((${#packages[@]})); then
  sudo pacman -Sy --noconfirm "${packages[@]}"
fi
sudo systemctl enable --now seatd
command -v Hyprland
command -v qs
command -v grim
command -v wtype
command -v python3
command -v seatd
systemctl is-active seatd
""".strip()
    setup = _run_ssh(record, setup_command, deadline - time.monotonic())
    (evidence / "guest-setup.log").write_text(
        setup.stdout + setup.stderr,
        encoding="utf-8",
    )
    if setup.returncode != 0:
        raise RuntimeError(f"guest package setup failed with exit code {setup.returncode}")


def _terminate_owned(record: dict, *, wait_seconds: float = 5.0) -> bool:
    if not owned_process(record):
        return False
    pid = int(record["qemu_pid"])
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if not owned_process(record):
            return True
        time.sleep(0.1)
    if owned_process(record):
        current = process_identity(pid)
        if current and current["pgid"] == int(record["qemu_pgid"]):
            os.killpg(current["pgid"], signal.SIGKILL)
    return True


def status(name: str) -> dict:
    record = dict(read_record(name))
    alive = owned_process(record)
    record["qemu_alive"] = alive
    if record.get("state") in ACTIVE_STATES and not alive:
        current = process_identity(record.get("qemu_pid", -1))
        record["state"] = "failed"
        if current is None:
            record["error"] = "owned QEMU is dead"
        else:
            record["error"] = "stale QEMU record: process identity changed"
    return record


def stop(name: str) -> dict:
    name = validate_name(name)
    record = read_record(name)
    if record["state"] == "stopped":
        return record
    pid = record.get("qemu_pid")
    current = process_identity(pid) if isinstance(pid, int) else None
    if current is not None and not owned_process(record):
        record["state"] = "failed"
        record["error"] = "ownership mismatch; refusing to signal process"
        _write_record(record)
        raise ValueError(record["error"])
    if current is None:
        record["state"] = "stopped"
        record["error"] = None
        _write_record(record)
        _release_port(default_runtime_root(), name, record.get("port"))
        return record

    record["state"] = "stopping"
    record["error"] = None
    _write_record(record)
    _terminate_owned(record)
    record["state"] = "stopped"
    _write_record(record)
    _release_port(default_runtime_root(), name, record.get("port"))
    return record


def start(
    name: str,
    *,
    source: Path,
    base_image: Path,
    mode: str,
    workspace: str | None = None,
) -> dict:
    name = validate_name(name)
    if mode not in {"standalone", "plugin"}:
        raise ValueError("mode must be standalone or plugin")
    paths = prepare_private_inputs(name, source=source, base_image=base_image)
    evidence = paths["evidence"]
    before = _capture_host_state(evidence, "before")
    if workspace is None:
        active = before["active_workspace"]
        workspace = str(active.get("name") or active.get("id"))
    if not workspace or any(character in workspace for character in "\r\n"):
        raise ValueError("workspace must be a nonempty single-line selector")

    runtime_root = default_runtime_root()
    record = {field: None for field in RECORD_FIELDS}
    record.update(
        {
            "name": name,
            "state": "starting",
            "source": str(paths["source"]),
            "mode": mode,
            "source_digest": "",
            "base_image": str(paths["base_image"]),
            "host_pid": os.getpid(),
            "config_path": "/home/admin/.config/smartdock/dock.json",
            "evidence_path": str(evidence),
            "error": None,
        }
    )
    _write_record(record)
    proc = None
    qemu_log = None
    try:
        _launch_rule(name, workspace)
        with _port_registry_lock(runtime_root):
            port = _reserve_port_locked(runtime_root, name)
            record["port"] = port
            argv = qemu_argv(paths, port)
            (paths["session"] / "qemu.argv").write_text(
                "\n".join(redact_argv(argv)) + "\n",
                encoding="utf-8",
            )
            qemu_log = (evidence / "qemu.log").open("w", encoding="utf-8")
            proc = subprocess.Popen(
                argv,
                start_new_session=True,
                stdout=qemu_log,
                stderr=subprocess.STDOUT,
                text=True,
            )
            identity = process_identity(proc.pid)
            if identity is None:
                raise RuntimeError("could not record QEMU process identity")
            record.update(
                {
                    "qemu_pid": identity["pid"],
                    "qemu_start_ticks": identity["start_ticks"],
                    "qemu_pgid": identity["pgid"],
                }
            )
            _write_record(record)
            _wait_for_owned_port(record)

        client = _place_owned_window(proc.pid, workspace)
        record["qemu_window_address"] = client["address"]
        _write_record(record)
        _disable_launch_rule(name)
        after_placement = _capture_host_state(evidence, "after-placement")
        if (
            after_placement["production_settings_sha256"]
            != before["production_settings_sha256"]
        ):
            raise RuntimeError("host production settings hash changed during launch")

        _wait_for_guest_setup(record, evidence)
        after_setup = _capture_host_state(evidence, "after-setup")
        if after_setup["production_settings_sha256"] != before["production_settings_sha256"]:
            raise RuntimeError("host production settings hash changed during guest setup")
        # Development-only: remain "starting" until Task 5 dock readiness.
        # Emit one flushed JSON line so a parallel status/stop invocation can proceed.
        record["error"] = None
        _write_record(record)
        print(
            json.dumps(
                {
                    "event": "guest_setup_complete",
                    "name": name,
                    "state": record["state"],
                    "port": record["port"],
                    "qemu_pid": record["qemu_pid"],
                    "qemu_window_address": record["qemu_window_address"],
                    "evidence_path": record["evidence_path"],
                },
                sort_keys=True,
            ),
            flush=True,
        )

        returncode = proc.wait()
        latest = read_record(name)
        if latest["state"] == "stopped":
            return latest
        latest["state"] = "failed"
        latest["error"] = f"QEMU exited unexpectedly with status {returncode}"
        _write_record(latest)
        _release_port(runtime_root, name, latest.get("port"))
        return latest
    except BaseException as exc:
        _disable_launch_rule(name)
        if record.get("qemu_pid") and owned_process(record):
            _terminate_owned(record)
        record["state"] = "failed"
        record["error"] = str(exc)
        _write_record(record)
        _release_port(runtime_root, name, record.get("port"))
        raise
    finally:
        if qemu_log is not None:
            qemu_log.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="dev-session")
    sub = parser.add_subparsers(dest="command", required=True)

    prepare = sub.add_parser(
        "prepare",
        help="Task-1 helper: reserve NAME and build private VM inputs without starting QEMU",
    )
    prepare.add_argument("name")
    prepare.add_argument("--source", type=Path, required=True)
    prepare.add_argument("--base-image", type=Path, required=True)

    start_parser = sub.add_parser("start", help="start and supervise one named VM")
    start_parser.add_argument("name")
    start_parser.add_argument("--source", type=Path, required=True)
    start_parser.add_argument("--base-image", type=Path, required=True)
    start_parser.add_argument("--mode", choices=("standalone", "plugin"), required=True)
    start_parser.add_argument("--workspace")

    status_parser = sub.add_parser("status", help="show one named VM's status")
    status_parser.add_argument("name")
    status_parser.add_argument("--json", action="store_true")

    stop_parser = sub.add_parser("stop", help="stop one exactly owned VM")
    stop_parser.add_argument("name")

    args = parser.parse_args(argv)
    if args.command == "prepare":
        paths = prepare_private_inputs(
            args.name,
            source=args.source,
            base_image=args.base_image,
        )
        print(paths["session"])
        return 0
    if args.command == "start":
        result = start(
            args.name,
            source=args.source,
            base_image=args.base_image,
            mode=args.mode,
            workspace=args.workspace,
        )
        print(json.dumps(result, sort_keys=True))
        return 0 if result["state"] == "stopped" else 1
    if args.command == "status":
        result = status(args.name)
        if args.json:
            print(json.dumps(result, sort_keys=True))
        else:
            print(f"{result['name']}: {result['state']}")
        return 0
    if args.command == "stop":
        result = stop(args.name)
        print(f"{result['name']}: {result['state']}")
        return 0
    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        print(f"error: command failed: {exc.cmd}: {detail}", file=sys.stderr)
        raise SystemExit(1) from exc
