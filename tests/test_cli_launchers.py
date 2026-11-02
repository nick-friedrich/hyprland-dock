#!/usr/bin/env python3
"""FDM-1044 filesystem regression suite; isolated HOME and XDG paths."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("launcher_cli_test", ROOT / "scripts/smartdock_cli.py")
CLI = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CLI)
spec = importlib.util.spec_from_file_location("launcher_manager_test", ROOT / "scripts/smartdock_launchers.py")
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)


class SelectiveLauncherTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.env = dict(os.environ, HOME=str(self.root / "home"),
                        XDG_DATA_HOME=str(self.root / "data"),
                        XDG_STATE_HOME=str(self.root / "state"),
                        PATH=str(self.root / "bin"))
        Path(self.env["PATH"]).mkdir()
        self.data = Path(self.env["XDG_DATA_HOME"])
        self.state = Path(self.env["XDG_STATE_HOME"]) / "dockrail/terminal-agent-launchers.json"

    def agent(self, command):
        executable = Path(self.env["PATH"]) / command
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o755)

    def desktop(self, suffix):
        return self.data / ("applications/smartdock-agent-" + suffix + ".desktop")

    def action(self, command):
        return M.manage(command, environ=self.env, bundle=ROOT)

    def test_selective_subset_is_ready_and_idempotent(self):
        self.assertEqual(CLI.AGENT_COMMANDS, tuple(row[0] for row in M.AGENTS))
        self.assertEqual(CLI.AGENT_LAUNCHERS, tuple(row[1] for row in M.AGENTS))
        self.agent("claude")
        self.agent("herdr")
        probes = CLI.ReadinessProbes(environ=self.env)
        self.assertEqual(probes.missing_agent_launchers(),
                         ["smartdock-agent-claude-code", "smartdock-agent-herdr"])
        result = self.action("add")
        self.assertEqual(result["availableAgents"], ["claude", "herdr"])
        self.assertEqual(len(result["added"]), 4)
        self.assertTrue(self.desktop("herdr").is_file())
        self.assertTrue(self.desktop("claude-code").is_file())
        self.assertFalse(self.desktop("pi").exists())
        self.assertEqual(probes.missing_agent_launchers(), [])
        from test_cli_doctor import FakeProbes, status, settings
        fake = FakeProbes()
        fake.missing_launchers = probes.missing_agent_launchers()
        feature = CLI.feature_readiness(status(), settings(), fake)["agentLaunchers"]
        self.assertEqual(feature["status"], "ready")
        self.assertEqual(feature["installation"], "installed")
        self.assertEqual(self.action("add")["added"], [])
        owned = json.loads(self.state.read_text(encoding="utf-8"))["files"]
        self.assertEqual(len(owned), 4)
        self.assertTrue(all(len(sha) == 64 for sha in owned.values()))
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)

    def test_no_detected_agents_need_no_launchers(self):
        self.assertEqual(self.action("add")["availableAgents"], [])
        self.assertFalse(self.state.exists())
        self.assertEqual(CLI.ReadinessProbes(self.env).missing_agent_launchers(), [])

    def test_remove_keeps_modified_and_untracked_files(self):
        self.agent("claude")
        self.action("add")
        modified = self.desktop("claude-code")
        modified.write_text(modified.read_text() + "\n# customized")
        foreign = self.desktop("pi")
        foreign.write_text("foreign")
        result = self.action("remove")
        self.assertIn("applications/smartdock-agent-claude-code.desktop", result["preserved"])
        self.assertIn("applications/smartdock-agent-pi.desktop", result["preserved"])
        self.assertEqual(foreign.read_text(), "foreign")
        self.assertIn("customized", modified.read_text())
        self.assertFalse((self.data / "icons/hicolor/scalable/apps/smartdock-agent-claude-code.svg").exists())
        self.assertIn("applications/smartdock-agent-claude-code.desktop",
                      json.loads(self.state.read_text())["files"])

    def test_foreign_collision_is_never_adopted_or_replaced(self):
        self.agent("herdr")
        foreign = self.desktop("herdr")
        foreign.parent.mkdir(parents=True)
        foreign.write_text("leave me alone")
        result = self.action("add")
        self.assertIn("applications/smartdock-agent-herdr.desktop", result["preserved"])
        self.assertEqual(foreign.read_text(), "leave me alone")
        self.assertNotIn("applications/smartdock-agent-herdr.desktop",
                         json.loads(self.state.read_text())["files"])
        self.action("remove")
        self.assertEqual(foreign.read_text(), "leave me alone")

    def test_modified_icon_and_symlink_are_preserved(self):
        self.agent("herdr")
        self.action("add")
        icon = self.data / "icons/hicolor/scalable/apps/smartdock-agent-herdr.svg"
        icon.write_text("custom icon")
        desktop = self.desktop("herdr")
        desktop.unlink()
        outside = self.root / "outside"
        outside.write_text("private")
        desktop.symlink_to(outside)
        result = self.action("remove")
        self.assertIn("applications/smartdock-agent-herdr.desktop", result["preserved"])
        self.assertIn("icons/hicolor/scalable/apps/smartdock-agent-herdr.svg", result["preserved"])
        self.assertTrue(desktop.is_symlink())
        self.assertEqual(outside.read_text(), "private")

    def test_manifest_rejects_a_different_data_home_without_losing_ownership(self):
        self.agent("herdr")
        self.action("add")
        original = self.env["XDG_DATA_HOME"]
        before = self.state.read_bytes()
        manifest = json.loads(before)
        self.assertEqual(manifest["apiVersion"], 2)
        self.assertEqual(manifest["dataHome"], str(self.data.resolve()))

        other_data = self.root / "other-data"
        self.env["XDG_DATA_HOME"] = str(other_data)
        try:
            for command in ("remove", "add"):
                with self.assertRaisesRegex(M.LauncherError, "another XDG_DATA_HOME"):
                    self.action(command)
        finally:
            self.env["XDG_DATA_HOME"] = original

        self.assertEqual(self.state.read_bytes(), before)
        self.assertTrue(self.desktop("herdr").is_file())
        self.assertFalse(other_data.exists())
        self.action("remove")
        self.assertFalse(self.desktop("herdr").exists())

    def test_legacy_manifest_requires_matching_files_before_binding(self):
        self.agent("herdr")
        self.action("add")
        legacy = json.loads(self.state.read_text())
        legacy["apiVersion"] = 1
        del legacy["dataHome"]
        self.state.write_text(json.dumps(legacy), encoding="utf-8")
        before = self.state.read_bytes()

        original = self.env["XDG_DATA_HOME"]
        self.env["XDG_DATA_HOME"] = str(self.root / "other-data")
        try:
            with self.assertRaisesRegex(M.LauncherError, "no matching files"):
                self.action("remove")
        finally:
            self.env["XDG_DATA_HOME"] = original
        self.assertEqual(self.state.read_bytes(), before)

        # A genuine existing v1 installation remains manageable and is bound
        # to its actual data root during the next operation.
        self.action("add")
        upgraded = json.loads(self.state.read_text())
        self.assertEqual(upgraded["apiVersion"], 2)
        self.assertEqual(upgraded["dataHome"], str(self.data.resolve()))
        self.action("remove")
        self.assertFalse(self.desktop("herdr").exists())

    def test_invalid_manifest_fails_closed(self):
        self.state.parent.mkdir(parents=True)
        self.state.write_text('{"apiVersion":1,"files":{"../../bad":"0"}}')
        with self.assertRaises(M.LauncherError):
            self.action("add")
        self.assertFalse(self.desktop("herdr").exists())

    def test_direct_cli_add_remove_do_not_require_qs_host(self):
        self.agent("herdr")
        env = dict(self.env, PATH=self.env["PATH"] + ":/usr/bin:/bin")
        cmd = [sys.executable, str(ROOT / "scripts/smartdock_cli.py"), "launchers"]
        added = subprocess.run(cmd + ["add", "--json"], env=env, capture_output=True,
                               text=True, timeout=10, check=True)
        reply = json.loads(added.stdout)
        self.assertEqual(reply["apiVersion"], 1)
        self.assertTrue(reply["ok"])
        self.assertIn("applications/smartdock-agent-herdr.desktop", reply["data"]["added"])
        removed = subprocess.run(cmd + ["remove", "--json"], env=env,
                                 capture_output=True, text=True, timeout=10, check=True)
        self.assertTrue(json.loads(removed.stdout)["ok"])
        self.assertFalse(self.desktop("herdr").exists())


if __name__ == "__main__":
    unittest.main()
