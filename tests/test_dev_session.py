import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from dev_session import (  # noqa: E402
    _wait_for_guest_setup,
    default_runtime_root,
    owned_process,
    prepare_private_inputs,
    process_identity,
    qemu_argv,
    read_record,
    reserve_port,
    session_dir,
    source_manifest,
    guest_capture,
    guest_exec,
    status,
    stop,
    sync_source,
    validate_name,
)


class ContractTests(unittest.TestCase):
    def test_name(self):
        self.assertEqual(validate_name("agent-a"), "agent-a")
        for value in ("", "A", "../a", "a/b", "a" * 33):
            with self.assertRaises(ValueError):
                validate_name(value)

    def test_qemu_target_is_private(self):
        paths = {
            "overlay": Path("/tmp/a/overlay.qcow2"),
            "vars": Path("/tmp/a/vars.fd"),
            "seed": Path("/tmp/a/seed.iso"),
        }
        argv = qemu_argv(paths, 22341)
        self.assertIn(
            "user,id=net0,hostfwd=tcp:127.0.0.1:22341-:22",
            argv,
        )
        self.assertIn(
            "file=/tmp/a/overlay.qcow2,if=virtio,format=qcow2,discard=unmap",
            argv,
        )
        self.assertIn("file=/tmp/a/vars.fd", " ".join(argv))
        self.assertIn("file=/tmp/a/seed.iso,media=cdrom,if=virtio,readonly=on", argv)

    def test_invalid_source_and_base_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = root / "state"
            runtime = root / "runtime"
            state.mkdir()
            runtime.mkdir()
            missing = root / "missing"
            with self.assertRaises(ValueError):
                prepare_private_inputs(
                    "agent-a",
                    source=missing,
                    base_image=missing,
                    state_root=state,
                    runtime_root=runtime,
                )


class PrivateInputsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-test-"))
        self.state = self.tmp / "state"
        self.runtime = self.tmp / "runtime"
        self.state.mkdir()
        self.runtime.mkdir()
        self.source = Path(__file__).resolve().parents[1]
        base = Path.home() / (
            ".local/state/smartdock/dev-sessions/_kvm-feasibility/images/"
            "Arch-Linux-x86_64-cloudimg.qcow2"
        )
        if not base.is_file():
            self.skipTest(f"missing verified base image: {base}")
        self.base = base

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_two_names_get_distinct_private_paths(self):
        a = prepare_private_inputs(
            "agent-a",
            source=self.source,
            base_image=self.base,
            state_root=self.state,
            runtime_root=self.runtime,
        )
        b = prepare_private_inputs(
            "agent-b",
            source=self.source,
            base_image=self.base,
            state_root=self.state,
            runtime_root=self.runtime,
        )
        for key in ("overlay", "vars", "seed", "ssh_key", "ssh_pub"):
            self.assertNotEqual(a[key], b[key])
            self.assertTrue(a[key].exists(), key)
            self.assertTrue(b[key].exists(), key)
        overlay_info = json.loads(
            subprocess.run(
                ["qemu-img", "info", "--output=json", str(a["overlay"])],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        )
        self.assertEqual(overlay_info["virtual-size"], 40 * 1024**3)
        self.assertEqual(a["ssh_key"].stat().st_mode & 0o777, 0o600)
        self.assertEqual(session_dir("agent-a", self.state), a["session"])
        with self.assertRaises(ValueError):
            prepare_private_inputs(
                "agent-a",
                source=self.source,
                base_image=self.base,
                state_root=self.state,
                runtime_root=self.runtime,
            )

    def test_process_identity_reads_start_ticks(self):
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            start_new_session=True,
        )
        try:
            ident = process_identity(proc.pid)
            self.assertIsNotNone(ident)
            self.assertEqual(ident["pid"], proc.pid)
            self.assertIsInstance(ident["start_ticks"], int)
            self.assertEqual(ident["pgid"], os.getpgid(proc.pid))
            self.assertIsNone(process_identity(2**30))
        finally:
            proc.terminate()
            proc.wait(timeout=5)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-lifecycle-"))
        self.state_home = self.tmp / "state-home"
        self.runtime_dir = self.tmp / "runtime"
        self.state_home.mkdir()
        self.runtime_dir.mkdir()
        self.env = mock.patch.dict(
            os.environ,
            {
                "XDG_STATE_HOME": str(self.state_home),
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
            },
        )
        self.env.start()

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_record(self, name, record):
        session = session_dir(name)
        session.mkdir(mode=0o700, parents=True)
        (session / "record.json").write_text(json.dumps(record), encoding="utf-8")

    def test_duplicate_name_cannot_reserve_second_port(self):
        runtime = default_runtime_root()
        first = reserve_port(runtime, "agent-a")
        self.assertGreaterEqual(first, 22000)
        self.assertLessEqual(first, 22999)
        with self.assertRaisesRegex(ValueError, "already has"):
            reserve_port(runtime, "agent-a")

    def test_port_occupied_by_another_listener_is_skipped(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        occupied = 22000
        try:
            listener.bind(("127.0.0.1", occupied))
            listener.listen()
        except OSError:
            occupied = 22000
        try:
            port = reserve_port(default_runtime_root(), "agent-b")
        finally:
            listener.close()
        self.assertNotEqual(port, occupied)

    def test_malformed_and_stale_records_are_reported(self):
        session = session_dir("agent-a")
        session.mkdir(mode=0o700, parents=True)
        (session / "record.json").write_text("{broken", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "malformed"):
            read_record("agent-a")

        self.write_record(
            "agent-b",
            {
                "name": "agent-b",
                "state": "starting",
                "qemu_pid": 2**30,
                "qemu_start_ticks": 1,
                "qemu_pgid": 2**30,
            },
        )
        result = status("agent-b")
        self.assertEqual(result["state"], "failed")
        self.assertFalse(result["qemu_alive"])
        self.assertIn("dead", result["error"])

    def test_changed_start_ticks_refuse_signal(self):
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            start_new_session=True,
        )
        try:
            ident = process_identity(proc.pid)
            self.assertIsNotNone(ident)
            record = {
                "name": "agent-a",
                "state": "starting",
                "qemu_pid": ident["pid"],
                "qemu_start_ticks": ident["start_ticks"],
                "qemu_pgid": ident["pgid"],
            }
            self.assertTrue(owned_process(record))
            record["qemu_start_ticks"] += 1
            self.assertFalse(owned_process(record))
            self.write_record("agent-a", record)

            with self.assertRaisesRegex(ValueError, "ownership mismatch"):
                stop("agent-a")
            self.assertIsNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.terminate()
            proc.wait(timeout=5)

    def test_stop_is_idempotent(self):
        self.write_record("agent-a", {"name": "agent-a", "state": "stopped"})
        self.assertEqual(stop("agent-a")["state"], "stopped")
        self.assertEqual(stop("agent-a")["state"], "stopped")

    def test_ssh_wait_writes_progress_json_each_attempt(self):
        evidence = self.tmp / "evidence"
        evidence.mkdir()
        ssh_calls = {"true": 0}

        def fake_ssh(_record, command, _timeout):
            if command == "true":
                ssh_calls["true"] += 1
                if ssh_calls["true"] == 1:
                    return mock.Mock(
                        returncode=255,
                        stderr="ssh: connect to host 127.0.0.1 port 22000: Connection refused\n",
                        stdout="",
                    )
                first = json.loads((evidence / "progress.json").read_text(encoding="utf-8"))
                self.assertEqual(first["attempt"], 1)
                self.assertEqual(first["last_ssh_returncode"], 255)
                self.assertIn("Connection refused", first["last_ssh_stderr"])
                datetime.fromisoformat(first["timestamp"])
                return mock.Mock(returncode=0, stderr="", stdout="")
            return mock.Mock(returncode=0, stderr="", stdout="ok")

        with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
            with mock.patch("dev_session.time.sleep"):
                _wait_for_guest_setup({"name": "agent-a", "port": 22000}, evidence)

        progress = json.loads((evidence / "progress.json").read_text(encoding="utf-8"))
        self.assertEqual(progress["attempt"], 2)
        self.assertEqual(progress["last_ssh_returncode"], 0)
        self.assertEqual(progress["last_ssh_stderr"], "")
        datetime.fromisoformat(progress["timestamp"])


def _git(cwd, *args, extra_env=None):
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
        env=env,
    )


def _init_candidate_repo(root: Path) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    _git(root, "init")
    (root / "tracked.txt").write_text("tracked-bytes\n", encoding="utf-8")
    (root / "dirty.txt").write_text("dirty-original\n", encoding="utf-8")
    (root / "path with spaces.txt").write_text("spaces\n", encoding="utf-8")
    (root / "ignored.txt").write_text("should-not-transfer\n", encoding="utf-8")
    (root / ".gitignore").write_text("ignored.txt\n", encoding="utf-8")
    os.symlink("tracked.txt", root / "link-to-tracked")
    _git(root, "add", "tracked.txt", "dirty.txt", "path with spaces.txt", ".gitignore", "link-to-tracked")
    _git(
        root,
        "-c",
        "user.email=dev-session@test",
        "-c",
        "user.name=dev-session",
        "commit",
        "-m",
        "init",
    )
    (root / "dirty.txt").write_text("dirty-edited\n", encoding="utf-8")
    (root / "untracked.txt").write_text("untracked-bytes\n", encoding="utf-8")
    return root


class SourceSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-sync-"))
        self.source = _init_candidate_repo(self.tmp / "source")
        self.state_home = self.tmp / "state-home"
        self.runtime_dir = self.tmp / "runtime"
        self.state_home.mkdir()
        self.runtime_dir.mkdir()
        self.env = mock.patch.dict(
            os.environ,
            {
                "XDG_STATE_HOME": str(self.state_home),
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
            },
        )
        self.env.start()
        self.session = session_dir("agent-sync")
        self.session.mkdir(parents=True)
        self.evidence = self.session / "evidence"
        self.evidence.mkdir()
        self.guest_root = self.tmp / "guest"
        self.guest_root.mkdir()
        self.record = {
            "name": "agent-sync",
            "state": "starting",
            "source": str(self.source),
            "source_digest": "prior-digest",
            "port": 22001,
            "qemu_pid": 1,
            "qemu_start_ticks": 1,
            "qemu_pgid": 1,
            "evidence_path": str(self.evidence),
            "error": None,
        }
        (self.session / "record.json").write_text(
            json.dumps(self.record), encoding="utf-8"
        )

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_manifest_tracks_dirty_untracked_spaces_and_skips_ignored(self):
        entries, digest = source_manifest(self.source)
        paths = {entry["path"] for entry in entries}
        self.assertIn("tracked.txt", paths)
        self.assertIn("dirty.txt", paths)
        self.assertIn("untracked.txt", paths)
        self.assertIn("path with spaces.txt", paths)
        self.assertIn("link-to-tracked", paths)
        self.assertNotIn("ignored.txt", paths)
        self.assertFalse(any(path == ".git" or path.startswith(".git/") for path in paths))
        self.assertEqual(len(digest), 64)

        dirty = next(entry for entry in entries if entry["path"] == "dirty.txt")
        self.assertEqual(dirty["kind"], "file")
        self.assertEqual(
            dirty["sha256"],
            hashlib.sha256(b"dirty.txt\0" + b"dirty-edited\n").hexdigest(),
        )
        link = next(entry for entry in entries if entry["path"] == "link-to-tracked")
        self.assertEqual(link["kind"], "symlink")
        self.assertEqual(
            link["sha256"],
            hashlib.sha256(b"link-to-tracked\0" + b"tracked.txt").hexdigest(),
        )

        before = digest
        (self.source / "dirty.txt").write_text("dirty-again\n", encoding="utf-8")
        _, after = source_manifest(self.source)
        self.assertNotEqual(before, after)

    def test_sync_archive_excludes_git_and_ignored_and_is_one_way(self):
        host_tracked = hashlib.sha256((self.source / "tracked.txt").read_bytes()).hexdigest()
        scp_calls = []

        def fake_scp(record, local, remote):
            self.assertEqual(record["name"], "agent-sync")
            self.assertTrue(str(remote).startswith("/tmp/") or str(remote).startswith("/home/admin/"))
            scp_calls.append((Path(local), remote))
            dest = self.guest_root / Path(remote).name
            shutil.copy2(local, dest)

        def fake_ssh(record, command, timeout):
            del timeout
            self.assertEqual(record["name"], "agent-sync")
            self.assertIn("/home/admin/smartdock-candidate", command)
            self.assertNotIn("virtiofs", command)
            tar_remote = next(remote for _, remote in scp_calls if str(remote).endswith(".tar"))
            guest_tar = self.guest_root / Path(tar_remote).name
            dest_new = self.guest_root / "smartdock-candidate.new"
            dest = self.guest_root / "smartdock-candidate"
            if dest_new.exists():
                shutil.rmtree(dest_new)
            dest_new.mkdir()
            with tarfile.open(guest_tar, "r") as tar:
                names = tar.getnames()
                self.assertNotIn("ignored.txt", names)
                self.assertFalse(any(name == ".git" or name.startswith(".git/") for name in names))
                self.assertIn("path with spaces.txt", names)
                self.assertIn("untracked.txt", names)
                tar.extractall(dest_new, filter="data")
            if dest.exists():
                shutil.rmtree(dest)
            dest_new.rename(dest)
            _, digest = source_manifest(self.source)
            return subprocess.CompletedProcess(command, 0, stdout=digest + "\n", stderr="")

        with mock.patch("dev_session._scp_to_guest", side_effect=fake_scp):
            with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
                with mock.patch("dev_session.owned_process", return_value=True):
                    digest = sync_source(self.record)

        self.assertTrue(scp_calls)
        guest_only = self.guest_root / "smartdock-candidate" / "GUEST-ONLY"
        guest_only.write_text("guest-marker\n", encoding="utf-8")
        (self.guest_root / "smartdock-candidate" / "tracked.txt").write_text(
            "mutated-on-guest\n", encoding="utf-8"
        )
        self.assertEqual(
            hashlib.sha256((self.source / "tracked.txt").read_bytes()).hexdigest(),
            host_tracked,
        )
        self.assertFalse((self.source / "GUEST-ONLY").exists())
        self.assertEqual(read_record("agent-sync")["source_digest"], digest)
        self.assertNotEqual(digest, "prior-digest")

    def test_sync_retains_prior_digest_when_guest_readback_mismatches(self):
        def fake_scp(record, local, remote):
            del record, remote
            Path(local).touch(exist_ok=True)

        def fake_ssh(_record, command, _timeout):
            return subprocess.CompletedProcess(command, 0, stdout="not-the-digest\n", stderr="")

        with mock.patch("dev_session._scp_to_guest", side_effect=fake_scp):
            with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
                with mock.patch("dev_session.owned_process", return_value=True):
                    with self.assertRaises(ValueError):
                        sync_source(self.record)
        self.assertEqual(read_record("agent-sync")["source_digest"], "prior-digest")

    def test_archive_rejects_file_changed_after_inventory(self):
        real_manifest = source_manifest

        def mutating_manifest(source):
            entries, digest = real_manifest(source)
            (source / "tracked.txt").write_text("changed-after-inventory\n", encoding="utf-8")
            return entries, digest

        with mock.patch("dev_session.source_manifest", side_effect=mutating_manifest):
            with mock.patch("dev_session.owned_process", return_value=True):
                with self.assertRaises(ValueError):
                    sync_source(self.record)
        self.assertEqual(read_record("agent-sync")["source_digest"], "prior-digest")


class GuestExecCaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-exec-"))
        self.state_home = self.tmp / "state-home"
        self.runtime_dir = self.tmp / "runtime"
        self.state_home.mkdir()
        self.runtime_dir.mkdir()
        self.env = mock.patch.dict(
            os.environ,
            {
                "XDG_STATE_HOME": str(self.state_home),
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
            },
        )
        self.env.start()
        self.session = session_dir("agent-exec")
        self.session.mkdir(parents=True)
        self.evidence = self.session / "evidence"
        self.evidence.mkdir()
        self.record = {
            "name": "agent-exec",
            "state": "starting",
            "source": str(Path(__file__).resolve().parents[1]),
            "source_digest": "abc123",
            "port": 22002,
            "qemu_pid": 1,
            "qemu_start_ticks": 1,
            "qemu_pgid": 1,
            "evidence_path": str(self.evidence),
            "error": None,
            "guest_display": "wayland-1",
            "guest_signature": "sig",
            "guest_output": "Virtual-1",
        }
        (self.session / "record.json").write_text(
            json.dumps(self.record), encoding="utf-8"
        )

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_exec_passes_literal_argv(self):
        captured = {}

        def fake_ssh(_record, command, _timeout):
            captured["command"] = command
            return subprocess.CompletedProcess(command, 0, stdout="ok\n", stderr="")

        unique = self.tmp / "host-should-not-create"
        with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
            with mock.patch("dev_session.owned_process", return_value=True):
                code = guest_exec(
                    "agent-exec", ["echo", f"$(touch {unique})"]
                )
        self.assertEqual(code, 0)
        self.assertIn(f"echo '$(touch {unique})'", captured["command"])
        self.assertFalse(unique.exists())

    def test_exec_returns_guest_exit_code(self):
        def fake_ssh(_record, command, _timeout):
            return subprocess.CompletedProcess(command, 17, stdout="", stderr="boom")

        with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
            with mock.patch("dev_session.owned_process", return_value=True):
                self.assertEqual(guest_exec("agent-exec", ["false"]), 17)

    def test_capture_rejects_non_png(self):
        def fake_ssh(_record, command, _timeout):
            if "grim" in command:
                return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=json.dumps(
                    {
                        "wayland_display": "wayland-1",
                        "hyprland_instance_signature": "sig",
                        "output": "Virtual-1",
                        "xdg_runtime_dir": "/run/user/1000",
                    }
                ),
                stderr="",
            )

        def fake_scp(_record, remote, local):
            del remote
            Path(local).write_text("not a png", encoding="utf-8")

        with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
            with mock.patch("dev_session._scp_from_guest", side_effect=fake_scp):
                with mock.patch("dev_session.owned_process", return_value=True):
                    with self.assertRaisesRegex(ValueError, "PNG"):
                        guest_capture("agent-exec")

    def test_exec_and_capture_reject_stopped_or_failed(self):
        for state in ("stopped", "failed"):
            self.record["state"] = state
            (self.session / "record.json").write_text(
                json.dumps(self.record), encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, state):
                guest_exec("agent-exec", ["true"])
            with self.assertRaisesRegex(ValueError, state):
                guest_capture("agent-exec")


if __name__ == "__main__":
    unittest.main()
