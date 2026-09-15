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
import shlex
import signal
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

GUEST_CANDIDATE = "/home/admin/smartdock-candidate"
GUEST_CANDIDATE_NEW = "/home/admin/smartdock-candidate.new"
GUEST_STATE_ROOT = "/home/admin/.local/state/smartdock/dev-sessions"
GUEST_CONFIG_PATH = "/home/admin/.config/smartdock/dock.json"
GUEST_OMARCHY_TEST = "/home/admin/smartdock-omarchy-test"
GUEST_CONTROL = f"{GUEST_CANDIDATE}/tests/runtime/dev-session/guest-control.sh"
GUEST_SMARTDOCK = f"{GUEST_CANDIDATE}/scripts/smartdock"
SMARTDOCK_PLUGIN_ID = "io.github.fernandodamaso.smartdock"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

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
    "guest_dock_pid",
    "config_path",
    "guest_config_path",
    "target",
    "evidence_path",
    "error",
)


def apply_guest_targeting(record: dict, *, recorded_state: str | None = None) -> dict:
    """Status/record view: CLI targeting is the named guest, never production."""
    view = dict(record)
    state = recorded_state if recorded_state is not None else view.get("state")
    view["target"] = "guest"
    view["guest_config_path"] = GUEST_CONFIG_PATH
    if not view.get("config_path"):
        view["config_path"] = GUEST_CONFIG_PATH
    if state == "starting" and view.get("guest_dock_pid") is None:
        view["guest_dock_pid"] = None
        view["host_pid"] = None
        return view
    pid = view.get("guest_dock_pid")
    if pid is None:
        pid = view.get("host_pid")
    view["guest_dock_pid"] = pid
    if pid is not None:
        view["host_pid"] = pid
    return view


def _guest_dock_pid(record: dict) -> int:
    raw = record.get("guest_dock_pid")
    if raw is None:
        raw = record.get("host_pid")
    try:
        pid = int(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError("recorded guest dock pid is missing") from exc
    if pid <= 0:
        raise ValueError("recorded guest dock pid is missing")
    return pid


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


def ssh_argv(record: dict, remote_command: str = "true") -> list[str]:
    """Exact SSH argv for NAME: private key, known-hosts, and reserved port."""
    name = validate_name(record.get("name", ""))
    if record.get("port") is None:
        raise ValueError(f"session {name!r} has no reserved port")
    return _ssh_argv(record, remote_command)


def _run_ssh(record: dict, command: str, timeout: float) -> subprocess.CompletedProcess:
    return subprocess.run(
        _ssh_argv(record, command),
        check=False,
        capture_output=True,
        text=True,
        timeout=max(1, timeout),
    )


def _scp_to_guest(record: dict, local: Path, remote: str) -> None:
    session = session_dir(record["name"])
    argv = [
        "scp",
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
        "-P",
        str(record["port"]),
        "--",
        str(local),
        f"admin@127.0.0.1:{remote}",
    ]
    result = subprocess.run(argv, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"scp to guest failed: {(result.stderr or result.stdout or '').strip()}")


def _scp_from_guest(record: dict, remote: str, local: Path) -> None:
    session = session_dir(record["name"])
    argv = [
        "scp",
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
        "-P",
        str(record["port"]),
        "--",
        f"admin@127.0.0.1:{remote}",
        str(local),
    ]
    result = subprocess.run(argv, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"scp from guest failed: {(result.stderr or result.stdout or '').strip()}"
        )


def _validate_relpath(rel: str) -> str:
    if not rel or rel.startswith("/") or rel.endswith("/"):
        raise ValueError(f"invalid source path: {rel!r}")
    parts = Path(rel).parts
    if any(part in (".", "..") for part in parts) or Path(rel).is_absolute():
        raise ValueError(f"path traversal rejected: {rel!r}")
    if rel == ".git" or rel.startswith(".git/"):
        raise ValueError(f".git path rejected: {rel!r}")
    return rel


def _hash_entry(path: str, payload: bytes) -> str:
    return hashlib.sha256(path.encode("utf-8") + b"\0" + payload).hexdigest()


def _manifest_digest(entries: list[dict]) -> str:
    digest = hashlib.sha256()
    for entry in entries:
        digest.update(entry["path"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(entry["kind"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(entry["sha256"].encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def _git_ls_files(source: Path) -> list[bytes]:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(source),
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or b"").decode("utf-8", "replace").strip()
        raise ValueError(f"git ls-files failed in {source}: {detail}")
    paths = [item for item in result.stdout.split(b"\0") if item]
    paths.sort()
    return paths


def source_manifest(source: Path) -> tuple[list[dict], str]:
    """Inventory Git-tracked and nonignored untracked files; hash working-tree bytes."""
    source = resolve_existing_dir(source, "source")
    entries = []
    for raw in _git_ls_files(source):
        rel = _validate_relpath(os.fsdecode(raw))
        full = source / rel
        if full.is_symlink():
            payload = os.fsencode(os.readlink(full))
            entries.append(
                {
                    "path": rel,
                    "kind": "symlink",
                    "sha256": _hash_entry(rel, payload),
                    "target": os.readlink(full),
                }
            )
        elif full.is_file():
            data = full.read_bytes()
            entries.append(
                {
                    "path": rel,
                    "kind": "file",
                    "sha256": _hash_entry(rel, data),
                    "size": len(data),
                }
            )
        else:
            raise ValueError(f"unsupported source path kind: {rel!r}")
    return entries, _manifest_digest(entries)


def _current_entry_hash(source: Path, entry: dict) -> str:
    full = source / entry["path"]
    if entry["kind"] == "symlink":
        if not full.is_symlink():
            raise ValueError(f"source path changed during archive: {entry['path']}")
        return _hash_entry(entry["path"], os.fsencode(os.readlink(full)))
    if full.is_symlink() or not full.is_file():
        raise ValueError(f"source path changed during archive: {entry['path']}")
    return _hash_entry(entry["path"], full.read_bytes())


def _write_source_archive(source: Path, entries: list[dict], tar_path: Path) -> None:
    tmp = tar_path.with_name(tar_path.name + ".tmp")
    with tarfile.open(tmp, "w") as tar:
        for entry in entries:
            if _current_entry_hash(source, entry) != entry["sha256"]:
                raise ValueError(f"source path changed during archive: {entry['path']}")
            tar.add(source / entry["path"], arcname=entry["path"], recursive=False)
    os.replace(tmp, tar_path)


GUEST_APPLY_SCRIPT = r"""
import hashlib, json, os, shutil, sys, tarfile
from pathlib import Path
def hash_entry(path, payload):
    return hashlib.sha256(path.encode("utf-8") + b"\0" + payload).hexdigest()
archive = Path(sys.argv[1])
manifest = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
dest_new = Path(sys.argv[3])
dest = Path(sys.argv[4])
if dest_new.exists():
    shutil.rmtree(dest_new)
dest_new.mkdir(parents=True)
with tarfile.open(archive, "r") as tar:
    tar.extractall(dest_new, filter="data")
for entry in manifest["entries"]:
    rel = entry["path"]
    parts = Path(rel).parts
    if (not rel) or rel.startswith("/") or any(part in (".", "..") for part in parts):
        raise SystemExit(f"invalid path {rel!r}")
    full = dest_new.joinpath(*parts)
    full.relative_to(dest_new)
    if entry["kind"] == "symlink":
        if not full.is_symlink():
            raise SystemExit(f"missing symlink {rel}")
        actual = hash_entry(rel, os.fsencode(os.readlink(full)))
    elif entry["kind"] == "file":
        if full.is_symlink() or not full.is_file():
            raise SystemExit(f"missing file {rel}")
        actual = hash_entry(rel, full.read_bytes())
    else:
        raise SystemExit(f"unsupported kind {entry['kind']}")
    if actual != entry["sha256"]:
        raise SystemExit(f"hash mismatch {rel}")
if dest.exists():
    shutil.rmtree(dest)
dest_new.rename(dest)
print(manifest["digest"], flush=True)
""".lstrip()


def _guest_sync_command(archive_remote: str, manifest_remote: str) -> str:
    return " ".join(
        [
            "python3",
            "-c",
            shlex.quote(GUEST_APPLY_SCRIPT),
            shlex.quote(archive_remote),
            shlex.quote(manifest_remote),
            shlex.quote(GUEST_CANDIDATE_NEW),
            shlex.quote(GUEST_CANDIDATE),
        ]
    )


def sync_source(record: dict) -> str:
    """Copy NAME's candidate source one-way into the guest and return the digest."""
    name = validate_name(record.get("name", ""))
    latest = dict(read_record(name))
    if latest.get("state") not in {"starting", "ready"}:
        raise ValueError(f"cannot sync session {name!r} in state {latest.get('state')!r}")
    if not owned_process(latest):
        raise ValueError(f"cannot sync session {name!r}: owned QEMU is not running")
    source = resolve_existing_dir(Path(latest["source"]), "source")
    evidence = Path(latest["evidence_path"])
    evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
    entries, digest = source_manifest(source)
    tar_path = evidence / "source-sync.tar"
    manifest_path = evidence / "source-sync.json"
    _write_source_archive(source, entries, tar_path)
    manifest_path.write_text(
        json.dumps({"digest": digest, "entries": entries}, indent=2) + "\n",
        encoding="utf-8",
    )
    archive_remote = f"/tmp/smartdock-sync-{name}.tar"
    manifest_remote = f"/tmp/smartdock-sync-{name}.json"
    _scp_to_guest(latest, tar_path, archive_remote)
    _scp_to_guest(latest, manifest_path, manifest_remote)
    result = _run_ssh(latest, _guest_sync_command(archive_remote, manifest_remote), 120)
    if result.returncode != 0:
        raise RuntimeError(
            f"guest sync failed with exit code {result.returncode}: "
            f"{(result.stderr or result.stdout or '').strip()}"
        )
    readback = (result.stdout or "").strip().splitlines()
    guest_digest = readback[-1] if readback else ""
    if guest_digest != digest:
        raise ValueError("guest source digest did not match host manifest")
    latest["source_digest"] = digest
    latest["error"] = None
    if latest.get("state") == "ready":
        _stop_guest_dock(latest)
        latest["state"] = "starting"
        latest["host_pid"] = None
        latest["guest_dock_pid"] = None
        latest["target"] = "guest"
        latest["guest_config_path"] = GUEST_CONFIG_PATH
        latest["error"] = "dock invalidated by source sync; restart through guest host contract"
    _write_record(latest)
    return digest


def _guest_ready_path(name: str) -> str:
    return f"{GUEST_STATE_ROOT}/{validate_name(name)}/ready.json"


def _require_runnable_session(name: str) -> dict:
    name = validate_name(name)
    record = read_record(name)
    state = record.get("state")
    if state in {"stopped", "failed"}:
        raise ValueError(f"cannot use session {name!r} in state {state!r}")
    if not owned_process(record):
        raise ValueError(f"cannot use session {name!r}: owned QEMU is not running")
    return record


def _guest_env_eval_script() -> str:
    return """
import json, os, shlex
ready = os.environ.get("READY", "")
if not ready or not os.path.isfile(ready):
    raise SystemExit(0)
data = json.load(open(ready, encoding="utf-8"))
mapping = (
    ("wayland_display", "WAYLAND_DISPLAY"),
    ("hyprland_instance_signature", "HYPRLAND_INSTANCE_SIGNATURE"),
    ("xdg_runtime_dir", "XDG_RUNTIME_DIR"),
)
for src, env in mapping:
    value = data.get(src)
    if value:
        print(f"export {env}={shlex.quote(str(value))}")
""".strip()


def _guest_exec_command(record: dict, argv: list[str]) -> str:
    if not argv:
        raise ValueError("exec requires a command")
    joined = shlex.join([str(part) for part in argv])
    ready = _guest_ready_path(record["name"])
    return (
        "set -euo pipefail; "
        f"export SMARTDOCK_SESSION_NAME={shlex.quote(record['name'])}; "
        f"export SMARTDOCK_CANDIDATE={shlex.quote(GUEST_CANDIDATE)}; "
        f"export SMARTDOCK_SESSION_MODE={shlex.quote(str(record.get('mode') or 'standalone'))}; "
        f"export READY={shlex.quote(ready)}; "
        f"eval \"$(python3 -c {shlex.quote(_guest_env_eval_script())})\"; "
        f"exec {joined}"
    )


def guest_exec(name: str, argv: list[str]) -> int:
    """Run ARGV in the named guest with literal quoting and compositor env."""
    record = _require_runnable_session(name)
    result = _run_ssh(record, _guest_exec_command(record, argv), 120)
    if result.stdout:
        sys.stdout.write(result.stdout)
        sys.stdout.flush()
    if result.stderr:
        sys.stderr.write(result.stderr)
        sys.stderr.flush()
    return int(result.returncode)


def _read_guest_ready(record: dict) -> dict:
    result = _run_ssh(record, f"cat {shlex.quote(_guest_ready_path(record['name']))}", 10)
    if result.returncode != 0:
        raise RuntimeError(
            "guest compositor readiness JSON is missing; start-compositor first"
        )
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"malformed guest readiness JSON: {exc}") from exc
    for key in ("wayland_display", "hyprland_instance_signature", "output"):
        if not data.get(key):
            raise RuntimeError(f"guest readiness missing {key}")
    return data


def _next_frame_path(evidence: Path) -> Path:
    numbers = []
    for path in evidence.glob("frame-*.png"):
        try:
            numbers.append(int(path.stem.split("-", 1)[1]))
        except (IndexError, ValueError):
            continue
    next_number = max(numbers, default=0) + 1
    return evidence / f"frame-{next_number:03d}.png"


def guest_capture(name: str) -> Path:
    """Capture one guest PNG into NAME's numbered evidence path."""
    record = _require_runnable_session(name)
    ready = _read_guest_ready(record)
    record["guest_display"] = ready["wayland_display"]
    record["guest_signature"] = ready["hyprland_instance_signature"]
    record["guest_output"] = ready["output"]
    _write_record(record)
    remote_png = f"/tmp/smartdock-capture-{record['name']}.png"
    runtime = ready.get("xdg_runtime_dir") or "/run/user/1000"
    command = " ".join(
        [
            f"export XDG_RUNTIME_DIR={shlex.quote(str(runtime))};",
            f"export WAYLAND_DISPLAY={shlex.quote(ready['wayland_display'])};",
            f"export HYPRLAND_INSTANCE_SIGNATURE={shlex.quote(ready['hyprland_instance_signature'])};",
            shlex.join(
                ["timeout", "10s", "grim", "-o", ready["output"], remote_png]
            ),
        ]
    )
    result = _run_ssh(record, command, 20)
    if result.returncode != 0:
        raise RuntimeError(
            f"guest grim capture failed or timed out: "
            f"{(result.stderr or result.stdout or '').strip()}"
        )
    evidence = Path(record["evidence_path"])
    evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
    local = _next_frame_path(evidence)
    _scp_from_guest(record, remote_png, local)
    data = local.read_bytes()
    if len(data) < 32 or data[:8] != PNG_SIGNATURE:
        local.unlink(missing_ok=True)
        raise ValueError("capture is not a valid PNG")
    config_path = Path(record.get("source") or "") / "config/dock.json"
    config_digest = (
        hashlib.sha256(config_path.read_bytes()).hexdigest()
        if config_path.is_file()
        else None
    )
    local.with_suffix(".json").write_text(
        json.dumps(
            {
                "source_digest": record.get("source_digest"),
                "config_digest": config_digest,
                "guest_output": ready["output"],
                "guest_display": ready["wayland_display"],
                "guest_signature": ready["hyprland_instance_signature"],
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    return local


def first_party_plugin_ids(plugins_root: Path) -> list[str]:
    """Read first-party plugin ids from installed-style manifest.json files."""
    root = Path(plugins_root)
    if not root.is_dir():
        raise ValueError(f"plugin manifest root is missing: {root}")
    ids = []
    for manifest in sorted(root.rglob("manifest.json")):
        data = json.loads(manifest.read_text(encoding="utf-8"))
        plugin_id = data.get("id")
        if not isinstance(plugin_id, str) or not plugin_id.strip():
            raise ValueError(f"plugin manifest missing id: {manifest}")
        ids.append(plugin_id.strip())
    return sorted(set(ids))


def plugin_shell_config(
    first_party_ids: list[str], plugin_id: str = SMARTDOCK_PLUGIN_ID
) -> dict:
    """Private guest shell.json: enable SmartDock, disable first-party plugins."""
    disabled = sorted({str(item) for item in first_party_ids if str(item) != plugin_id})
    return {
        "version": 1,
        "bar": {
            "position": "top",
            "transparent": True,
            "layout": {"left": [], "center": [], "right": []},
        },
        "plugins": [{"id": plugin_id}],
        "disabledPlugins": disabled,
    }


def dock_argv(record: dict, args: list[str]) -> list[str]:
    """Build candidate CLI argv with exact recorded runtime/instance selectors."""
    parts = [str(part) for part in args]
    for part in parts:
        if part in {"--instance", "--runtime"} or part.startswith("--instance=") or part.startswith(
            "--runtime="
        ):
            raise ValueError("dock argv cannot override --runtime or --instance")
    mode = record.get("mode")
    if mode not in {"standalone", "plugin"}:
        raise ValueError("record mode must be standalone or plugin")
    try:
        host_pid = _guest_dock_pid(record)
    except ValueError as exc:
        raise ValueError("record host_pid is required") from exc
    return [
        GUEST_SMARTDOCK,
        "--runtime",
        mode,
        "--instance",
        str(host_pid),
        *parts,
    ]


def qualify_guest_dock(record: dict, status_reply: dict) -> dict:
    """Require exact mode, PID, private config path and loaded state."""
    if not isinstance(status_reply, dict) or not status_reply.get("ok"):
        raise ValueError("guest dock status is not ok")
    data = status_reply.get("data")
    if not isinstance(data, dict):
        raise ValueError("guest dock status data is missing")
    runtime = data.get("runtime")
    if not isinstance(runtime, dict):
        raise ValueError("guest dock runtime is missing")
    expected_mode = record.get("mode")
    try:
        expected_pid = str(_guest_dock_pid(record))
    except ValueError as exc:
        raise ValueError("record host_pid is required") from exc
    expected_config = record.get("guest_config_path") or record.get("config_path") or GUEST_CONFIG_PATH
    if runtime.get("mode") != expected_mode:
        raise ValueError(
            f"guest dock mode {runtime.get('mode')!r} does not match {expected_mode!r}"
        )
    if str(runtime.get("instanceId")) != expected_pid:
        raise ValueError(
            f"guest dock pid {runtime.get('instanceId')!r} does not match {expected_pid!r}"
        )
    if data.get("configPath") != expected_config:
        raise ValueError(
            f"guest dock config path {data.get('configPath')!r} does not match {expected_config!r}"
        )
    if data.get("loadState") != "loaded":
        raise ValueError(f"guest dock loadState {data.get('loadState')!r} is not loaded")
    return data


def _last_json_value(text: str):
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    if not lines:
        raise ValueError("expected JSON output")
    try:
        return json.loads(lines[-1])
    except json.JSONDecodeError:
        return json.loads(text)


def _run_guest_argv(
    record: dict, argv: list[str], timeout: float
) -> subprocess.CompletedProcess:
    return _run_ssh(record, _guest_exec_command(record, argv), timeout)


def _parse_qs_instances(text: str) -> list[dict]:
    stripped = (text or "").strip()
    if stripped in {"", "No running instances."}:
        return []
    values = json.loads(stripped)
    if not isinstance(values, list):
        raise RuntimeError("qs list --all --json did not return an array")
    return values


def _guest_qs_instances(record: dict) -> list[dict]:
    result = _run_guest_argv(record, ["qs", "list", "--all", "--json"], 15)
    if result.returncode != 0:
        raise RuntimeError(
            "guest qs list --all --json failed: "
            f"{(result.stderr or result.stdout or '').strip()}"
        )
    try:
        return _parse_qs_instances(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"malformed guest qs list JSON: {exc}") from exc


def _host_omarchy_root() -> Path:
    return Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"))


def _host_omarchy_shell() -> Path:
    return _host_omarchy_root() / "shell"


def _extract_omarchy_archive(record: dict, tar_path: Path, remote: str, tests: list[str]) -> None:
    extract = r"""
import os, tarfile, sys
from pathlib import Path
dest = Path(sys.argv[1])
archive = Path(sys.argv[2])
dest.mkdir(parents=True, exist_ok=True)
for path in [dest, *dest.rglob("*")]:
    try:
        mode = path.stat().st_mode
        path.chmod(mode | 0o200)
    except OSError:
        pass
with tarfile.open(archive, "r") as tar:
    tar.extractall(dest, filter="data")
""".strip()
    _scp_to_guest(record, tar_path, remote)
    checks = " && ".join(tests)
    command = (
        f"python3 -c {shlex.quote(extract)} {shlex.quote(GUEST_OMARCHY_TEST)} "
        f"{shlex.quote(remote)} && chmod -R a-w {shlex.quote(GUEST_OMARCHY_TEST)}"
        + (f" && {checks}" if checks else "")
    )
    result = _run_ssh(record, command, 60)
    if result.returncode != 0:
        raise RuntimeError(
            "failed to stage guest Omarchy test assets: "
            f"{(result.stderr or result.stdout or '').strip()}"
        )


def stage_omarchy_qml_assets(record: dict) -> None:
    """Copy current Omarchy Commons/Ui into the guest as read-only test assets."""
    shell = _host_omarchy_shell()
    commons = shell / "Commons"
    ui = shell / "Ui"
    if not commons.is_dir() or not ui.is_dir():
        raise RuntimeError(
            f"host Omarchy Commons/Ui missing at {shell}; "
            "cannot stage guest standalone test assets"
        )
    evidence = Path(record["evidence_path"])
    evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
    tar_path = evidence / "omarchy-qml-assets.tar"
    tmp = tar_path.with_name(tar_path.name + ".tmp")
    with tarfile.open(tmp, "w") as tar:
        tar.add(commons, arcname="shell/Commons")
        tar.add(ui, arcname="shell/Ui")
    os.replace(tmp, tar_path)
    _extract_omarchy_archive(
        record,
        tar_path,
        f"/tmp/smartdock-omarchy-qml-{record['name']}.tar",
        [
            f"test -d {shlex.quote(GUEST_OMARCHY_TEST + '/shell/Commons')}",
            f"test -d {shlex.quote(GUEST_OMARCHY_TEST + '/shell/Ui')}",
        ],
    )


def stage_omarchy_plugin_host(record: dict) -> dict:
    """Copy Omarchy shell host, first-party plugins, and defaults into the guest."""
    root = _host_omarchy_root()
    shell = root / "shell"
    defaults = root / "config" / "omarchy" / "shell.json"
    version = root / "version"
    registry = shell / "services" / "PluginRegistry.qml"
    if not (shell / "shell.qml").is_file() or not registry.is_file() or not defaults.is_file():
        raise RuntimeError(
            f"host Omarchy plugin host files missing under {root}; "
            "cannot stage guest plugin test assets"
        )
    evidence = Path(record["evidence_path"])
    evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
    inspected = {
        "omarchy_package": "omarchy 4.0.3-1",
        "omarchy_version_file": version.read_text(encoding="utf-8").strip() if version.is_file() else None,
        "shell_qml_sha256": hashlib.sha256((shell / "shell.qml").read_bytes()).hexdigest(),
        "plugin_registry_sha256": hashlib.sha256(registry.read_bytes()).hexdigest(),
        "first_party_plugin_ids": first_party_plugin_ids(shell / "plugins"),
    }
    (evidence / "omarchy-revision.json").write_text(
        json.dumps(inspected, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    tar_path = evidence / "omarchy-plugin-host.tar"
    tmp = tar_path.with_name(tar_path.name + ".tmp")
    with tarfile.open(tmp, "w") as tar:
        tar.add(shell, arcname="shell")
        tar.add(defaults, arcname="config/omarchy/shell.json")
        if version.is_file():
            tar.add(version, arcname="version")
    os.replace(tmp, tar_path)
    _extract_omarchy_archive(
        record,
        tar_path,
        f"/tmp/smartdock-omarchy-plugin-{record['name']}.tar",
        [
            f"test -f {shlex.quote(GUEST_OMARCHY_TEST + '/shell/shell.qml')}",
            f"test -f {shlex.quote(GUEST_OMARCHY_TEST + '/shell/services/PluginRegistry.qml')}",
            f"test -d {shlex.quote(GUEST_OMARCHY_TEST + '/shell/plugins')}",
        ],
    )
    return inspected


def _host_theme_files() -> tuple[Path, Path]:
    current = Path.home() / ".local/state/omarchy/current/theme"
    colors = current / "colors.toml"
    shell_toml = current / "shell.toml"
    if colors.is_file() and shell_toml.is_file():
        return colors, shell_toml
    packaged = _host_omarchy_root() / "themes" / "tokyo-night"
    colors = packaged / "colors.toml"
    shell_toml = packaged / "shell.toml"
    if not colors.is_file():
        raise RuntimeError("no Omarchy theme colors.toml available to copy into the guest")
    return colors, shell_toml


def install_guest_plugin_runtime(record: dict, inspected: dict) -> None:
    """Private guest shell.json, plugin symlink, and read-only theme copy."""
    config = plugin_shell_config(inspected["first_party_plugin_ids"])
    evidence = Path(record["evidence_path"])
    local_shell = evidence / "guest-plugin-shell.json"
    local_shell.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    colors, shell_toml = _host_theme_files()
    _run_ssh(
        record,
        "mkdir -p /home/admin/.config/omarchy/plugins "
        "/home/admin/.local/state/omarchy/current/theme",
        10,
    )
    _scp_to_guest(record, local_shell, "/home/admin/.config/omarchy/shell.json")
    _scp_to_guest(
        record, colors, "/home/admin/.local/state/omarchy/current/theme/colors.toml"
    )
    _scp_to_guest(
        record, shell_toml, "/home/admin/.local/state/omarchy/current/theme/shell.toml"
    )
    link = _run_ssh(
        record,
        "ln -sfn /home/admin/smartdock-candidate "
        f"/home/admin/.config/omarchy/plugins/{shlex.quote(SMARTDOCK_PLUGIN_ID)} "
        f"&& chmod a-w /home/admin/.local/state/omarchy/current/theme/colors.toml "
        f"/home/admin/.local/state/omarchy/current/theme/shell.toml "
        f"&& test -e /home/admin/.config/omarchy/plugins/{shlex.quote(SMARTDOCK_PLUGIN_ID)}/Overlay.qml",
        10,
    )
    if link.returncode != 0:
        raise RuntimeError(
            "failed to install guest plugin runtime files: "
            f"{(link.stderr or link.stdout or '').strip()}"
        )


def _stop_guest_dock(record: dict) -> None:
    result = _run_guest_argv(record, [GUEST_CONTROL, "stop-dock"], 20)
    if result.returncode != 0:
        raise RuntimeError(
            "guest stop-dock failed: "
            f"{(result.stderr or result.stdout or '').strip()}"
        )


def _guest_smartdock_status(record: dict) -> dict:
    argv = dock_argv(record, ["status", "--json"])
    result = _run_guest_argv(record, argv, 20)
    if result.returncode != 0:
        raise RuntimeError(
            "guest smartdock status failed: "
            f"{(result.stderr or result.stdout or '').strip()}"
        )
    try:
        return _last_json_value(result.stdout)
    except (json.JSONDecodeError, ValueError) as exc:
        raise RuntimeError(f"malformed guest smartdock status JSON: {exc}") from exc


def start_guest_dock(name: str) -> dict:
    """Launch candidate scripts/run in the guest and qualify the exact host."""
    record = _require_runnable_session(name)
    ready = _read_guest_ready(record)
    record["guest_display"] = ready["wayland_display"]
    record["guest_signature"] = ready["hyprland_instance_signature"]
    record["guest_output"] = ready["output"]
    record["config_path"] = GUEST_CONFIG_PATH
    record["guest_config_path"] = GUEST_CONFIG_PATH
    record["target"] = "guest"
    _write_record(record)
    _stop_guest_dock(record)
    if record.get("mode") == "plugin":
        inspected = stage_omarchy_plugin_host(record)
        install_guest_plugin_runtime(record, inspected)
    else:
        stage_omarchy_qml_assets(record)
        inspected = None
    started = _run_guest_argv(record, [GUEST_CONTROL, "start-dock"], 120)
    if started.returncode != 0:
        raise RuntimeError(
            "guest start-dock failed: "
            f"{(started.stderr or started.stdout or '').strip()}"
        )
    try:
        payload = _last_json_value(started.stdout)
    except (json.JSONDecodeError, ValueError) as exc:
        raise RuntimeError(f"malformed guest start-dock JSON: {exc}") from exc
    try:
        launched_pid = int(payload["pid"])
    except (KeyError, TypeError, ValueError) as exc:
        raise RuntimeError(f"guest start-dock did not report a pid: {payload!r}") from exc
    if launched_pid <= 0:
        raise RuntimeError(f"guest start-dock reported invalid pid {launched_pid}")
    instances = _guest_qs_instances(record)
    matches = [item for item in instances if item.get("pid") == launched_pid]
    if len(matches) != 1:
        raise RuntimeError(
            f"qs list --all --json did not contain the launched dock pid {launched_pid}"
        )
    record["host_pid"] = launched_pid
    record["guest_dock_pid"] = launched_pid
    if payload.get("config_path"):
        record["config_path"] = str(payload["config_path"])
        record["guest_config_path"] = str(payload["config_path"])
    _write_record(record)
    deadline = time.monotonic() + 45
    last_error = "guest dock did not become loaded"
    qualified = None
    while time.monotonic() < deadline:
        try:
            reply = _guest_smartdock_status(record)
            qualified = qualify_guest_dock(record, reply)
            break
        except (RuntimeError, ValueError) as exc:
            last_error = str(exc)
            time.sleep(1)
    if qualified is None:
        raise RuntimeError(last_error)
    record["state"] = "ready"
    record["error"] = None
    _write_record(record)
    evidence = Path(record["evidence_path"])
    (evidence / "guest-dock-status.json").write_text(
        json.dumps(
            {
                "pid": launched_pid,
                "qs_instance": matches[0],
                "status": qualified,
                "mode": record.get("mode"),
                "omarchy": inspected,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    return record


def guest_dock(name: str, argv: list[str]) -> int:
    """Run candidate smartdock ARGV in the guest with exact recorded selectors."""
    record = _require_runnable_session(name)
    if record.get("state") != "ready":
        raise ValueError(f"cannot use session {name!r} dock in state {record.get('state')!r}")
    try:
        host_pid = _guest_dock_pid(record)
    except ValueError as exc:
        raise ValueError("recorded guest dock pid is missing") from exc
    instances = _guest_qs_instances(record)
    if not any(item.get("pid") == host_pid for item in instances):
        record["state"] = "starting"
        record["error"] = (
            f"recorded guest dock pid {host_pid} is gone; not guessing a replacement"
        )
        _write_record(record)
        raise RuntimeError(record["error"])
    return guest_exec(name, dock_argv(record, argv))


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
pacman -Q qt6-5compat >/dev/null 2>&1 || packages+=(qt6-5compat)
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
    recorded_state = record.get("state")
    alive = owned_process(record)
    record["qemu_alive"] = alive
    if record.get("state") in ACTIVE_STATES and not alive:
        current = process_identity(record.get("qemu_pid", -1))
        record["state"] = "failed"
        if current is None:
            record["error"] = "owned QEMU is dead"
        else:
            record["error"] = "stale QEMU record: process identity changed"
    return apply_guest_targeting(record, recorded_state=recorded_state)


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
            "host_pid": None,
            "guest_dock_pid": None,
            "config_path": GUEST_CONFIG_PATH,
            "guest_config_path": GUEST_CONFIG_PATH,
            "target": "guest",
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
        sync_source(record)
        record = read_record(name)
        compositor = _run_guest_argv(record, [GUEST_CONTROL, "start-compositor"], 90)
        if compositor.returncode != 0:
            raise RuntimeError(
                "guest compositor failed: "
                f"{(compositor.stderr or compositor.stdout or '').strip()}"
            )
        record = start_guest_dock(name)
        after_setup = _capture_host_state(evidence, "after-setup")
        if after_setup["production_settings_sha256"] != before["production_settings_sha256"]:
            raise RuntimeError("host production settings hash changed during guest setup")
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
                    "host_pid": record["host_pid"],
                    "guest_dock_pid": record.get("guest_dock_pid"),
                    "config_path": record["config_path"],
                    "guest_config_path": record.get("guest_config_path"),
                    "target": "guest",
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

    sync_parser = sub.add_parser("sync", help="copy candidate source one-way into the named guest")
    sync_parser.add_argument("name")

    exec_parser = sub.add_parser("exec", help="run a literal command in the named guest")
    exec_parser.add_argument("name")
    exec_parser.add_argument("argv", nargs=argparse.REMAINDER)

    capture_parser = sub.add_parser("capture", help="copy one guest grim PNG into NAME evidence")
    capture_parser.add_argument("name")

    dock_parser = sub.add_parser("dock", help="run candidate smartdock in the named guest")
    dock_parser.add_argument("name")
    dock_parser.add_argument("argv", nargs=argparse.REMAINDER)

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
    if args.command == "sync":
        print(sync_source(read_record(args.name)))
        return 0
    if args.command == "exec":
        argv = list(args.argv)
        if argv[:1] == ["--"]:
            argv = argv[1:]
        if not argv:
            parser.error("exec requires a command after --")
        return guest_exec(args.name, argv)
    if args.command == "capture":
        print(guest_capture(args.name))
        return 0
    if args.command == "dock":
        argv = list(args.argv)
        if argv[:1] == ["--"]:
            argv = argv[1:]
        if not argv:
            start_guest_dock(args.name)
            result = status(args.name)
            print(json.dumps(result, sort_keys=True))
            return 0
        return guest_dock(args.name, argv)
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
