#!/usr/bin/env python3
"""Ownership-safe installation of selectively detected terminal agents."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile

# Executable, desktop ID, icon extension. Keep in sync with CLI readiness.
AGENTS = (
    ("pi", "smartdock-agent-pi", "png"),
    ("omp", "smartdock-agent-oh-my-pi", "svg"),
    ("commandcode", "smartdock-agent-command-code", "svg"),
    ("cursor-agent", "smartdock-agent-cursor", "svg"),
    ("claude", "smartdock-agent-claude-code", "svg"),
    ("kilo", "smartdock-agent-kilo-code", "svg"),
    ("cline", "smartdock-agent-cline", "svg"),
    ("herdr", "smartdock-agent-herdr", "svg"),
)


class LauncherError(Exception):
    pass


def _roots(env):
    home = Path(env.get("HOME") or Path.home())
    data = Path(env.get("XDG_DATA_HOME") or home / ".local/share")
    state = Path(env.get("XDG_STATE_HOME") or home / ".local/state")
    return data, state / "dockrail/terminal-agent-launchers.json"


def _asset_dir(bundle):
    bundle = Path(bundle)
    candidates = [bundle]
    for marker in (".plugin-dir", ".source-dir"):
        file = bundle / marker
        if file.is_file() and not file.is_symlink():
            candidate = Path(file.read_text(encoding="utf-8").strip())
            if candidate.is_absolute():
                candidates.append(candidate)
    for candidate in candidates:
        path = candidate / "assets/terminal-agents"
        if path.is_dir():
            return path
    raise LauncherError("Terminal-agent assets unavailable; install from a Dockrail source/plugin tree.")


def _paths(agent):
    _, desktop_id, extension = agent
    icon_size = "scalable" if extension == "svg" else "256x256"
    return ("applications/" + desktop_id + ".desktop",
            "icons/hicolor/" + icon_size + "/apps/" + desktop_id + "." + extension)


ALLOWED = {path for agent in AGENTS for path in _paths(agent)}


def _read_state(path, data):
    if not os.path.lexists(path):
        return {}, False
    try:
        if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode) or path.stat().st_size > 65536:
            raise ValueError("manifest must be a regular file under 64 KiB")
        manifest = json.loads(path.read_text(encoding="utf-8"))
        files = manifest["files"]
        version = manifest.get("apiVersion")
        if (version not in (1, 2) or not isinstance(files, dict)
                or any(key not in ALLOWED or not isinstance(value, str)
                       or len(value) != 64 or any(c not in "0123456789abcdef" for c in value)
                       for key, value in files.items())):
            raise ValueError("invalid ownership entries")
        data_home = str(data.resolve())
        if version == 2:
            if manifest.get("dataHome") != data_home:
                raise ValueError("launcher manifest belongs to another XDG_DATA_HOME")
            return dict(files), False
        # Legacy v1 manifests have no data-root binding. Do not adopt ownership
        # from an unrelated data root without a matching installed asset.
        if files and not any(
                _digest(data / relative) == checksum
                for relative, checksum in files.items()
                if os.path.lexists(data / relative)):
            raise ValueError("unscoped legacy launcher manifest has no matching files in XDG_DATA_HOME")
        return dict(files), True
    except (OSError, ValueError, UnicodeError, KeyError, TypeError) as error:
        raise LauncherError("Invalid launcher ownership manifest; refusing changes: "
                            + str(error)) from error


def _persist(path, files, data):
    if path.is_symlink():
        raise LauncherError("Refusing symlink ownership manifest.")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".launchers-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump({"apiVersion": 2, "dataHome": str(data.resolve()),
                       "files": files}, output, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def _digest(path):
    if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode):
        return None
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(65536), b""):
            checksum.update(block)
    return checksum.hexdigest()


def _create(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
    with os.fdopen(fd, "wb") as output:
        output.write(content)
        output.flush()
        os.fsync(output.fileno())


def manage(action, environ=None, bundle=None):
    """Explicit add/remove; never modifies dock.json or installed plugin assets."""
    if action not in ("add", "remove"):
        raise LauncherError("Expected launchers add or remove.")
    env = dict(os.environ if environ is None else environ)
    data, manifest = _roots(env)
    owned, legacy = _read_state(manifest, data)
    if legacy:
        # Bind validated legacy ownership before an operation can remove entries.
        _persist(manifest, owned, data)
    assets = _asset_dir(bundle) if action == "add" else None
    result = {"added": [], "removed": [], "alreadyInstalled": [],
              "preserved": [], "missing": [], "availableAgents": []}
    for agent in AGENTS:
        command = agent[0]
        if action == "add":
            if not shutil.which(command, path=env.get("PATH")):
                continue
            result["availableAgents"].append(command)
        for relative in _paths(agent):
            if action == "remove" and relative not in owned:
                # Never remove a foreign file, but surface it to the caller.
                target = data / relative
                if os.path.lexists(target):
                    result["preserved"].append(relative)
                continue
            target = data / relative
            try:
                exists = os.path.lexists(target)
                current = _digest(target) if exists else None
                expected = owned.get(relative)
                if action == "remove":
                    if not exists:
                        del owned[relative]
                        _persist(manifest, owned, data)
                        result["missing"].append(relative)
                    elif current == expected:
                        target.unlink()
                        del owned[relative]
                        _persist(manifest, owned, data)
                        result["removed"].append(relative)
                    else:
                        result["preserved"].append(relative)
                    continue
                if exists:
                    bucket = "alreadyInstalled" if expected is not None and current == expected else "preserved"
                    result[bucket].append(relative)
                    continue
                source = assets / Path(relative).name
                if not source.is_file() or source.is_symlink():
                    raise LauncherError("Packaged launcher asset missing: " + str(source))
                content = source.read_bytes()
                digest = hashlib.sha256(content).hexdigest()
                _create(target, content)
                try:
                    owned[relative] = digest
                    _persist(manifest, owned, data)
                except Exception:
                    owned.pop(relative, None)
                    if _digest(target) == digest:
                        target.unlink()
                    raise
                result["added"].append(relative)
            except OSError as error:
                raise LauncherError("Failed to manage " + relative + ": " + str(error)) from error
    result["changed"] = bool(result["added"] or result["removed"])
    result["statePath"] = str(manifest)
    return result
