#!/usr/bin/env python3
"""Foreground KVM SmartDock development sessions (host supervisor)."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
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

    args = parser.parse_args(argv)
    if args.command == "prepare":
        paths = prepare_private_inputs(
            args.name,
            source=args.source,
            base_image=args.base_image,
        )
        print(paths["session"])
        return 0
    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        print(f"error: command failed: {exc.cmd}: {detail}", file=sys.stderr)
        raise SystemExit(1) from exc
