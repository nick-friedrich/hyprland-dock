import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from dev_session import (  # noqa: E402
    prepare_private_inputs,
    process_identity,
    qemu_argv,
    session_dir,
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


if __name__ == "__main__":
    unittest.main()
