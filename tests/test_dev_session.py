import json
import os
import shutil
import socket
import subprocess
import sys
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
    status,
    stop,
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
        listener.bind(("127.0.0.1", 22000))
        listener.listen()
        try:
            port = reserve_port(default_runtime_root(), "agent-b")
        finally:
            listener.close()
        self.assertNotEqual(port, 22000)

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


if __name__ == "__main__":
    unittest.main()
