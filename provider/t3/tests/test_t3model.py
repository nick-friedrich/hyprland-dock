# SPDX-License-Identifier: Apache-2.0
"""Tests for provider/t3/t3model.py classification and snapshots."""
from __future__ import annotations

import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import t3model
from t3model import (
    BuildState,
    ShellStore,
    StatusTracker,
    agent_kind,
    build_snapshot,
    classify,
    clean_text,
    finalize_snapshot,
    snapshot_fingerprint,
    unread,
    visible_threads,
)

NOW_MS = int(datetime(2026, 10, 23, 17, 0, tzinfo=timezone.utc).timestamp() * 1000)

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def thread(**overrides: object) -> dict[str, object]:
    base: dict[str, object] = {
        "id": "thread-1",
        "status": "completed",
        "projectId": "project-1",
        "title": "Example thread",
        "updatedAt": "2026-10-23T16:00:00.000Z",
    }
    base.update(overrides)
    return base


def live_state(**overrides: object) -> BuildState:
    params: dict[str, object] = {
        "epoch": "epoch",
        "revision": 1,
        "server_id": "t3:env-1",
        "health": "live",
        "error_code": None,
        "generation": 1,
        "now_ms": NOW_MS,
        "inventory_live": True,
    }
    params.update(overrides)
    return BuildState(**params)  # type: ignore[arg-type]


def live_snapshot(
    store: ShellStore, **overrides: object
) -> dict[str, object]:
    return build_snapshot(live_state(**overrides), store, StatusTracker())


class ClassifyTests(unittest.TestCase):
    def test_pending_runtime_request_is_blocked(self) -> None:
        t = thread(status="running", pendingRuntimeRequest={"kind": "approval"})
        self.assertEqual(classify(t, NOW_MS), "blocked")

    def test_actionable_plan_is_blocked(self) -> None:
        t = thread(status="idle", hasActionableProposedPlan=True)
        self.assertEqual(classify(t, NOW_MS), "blocked")

    def test_activity_run_status_is_working(self) -> None:
        for activity in ("preparing", "starting", "running", "waiting"):
            with self.subTest(activity=activity):
                t = thread(status="completed", activityRunStatus=activity)
                self.assertEqual(classify(t, NOW_MS), "working")

    def test_status_working_set(self) -> None:
        for status in ("queued", "preparing", "starting", "running", "waiting"):
            with self.subTest(status=status):
                self.assertEqual(classify(thread(status=status), NOW_MS), "working")

    def test_background_tasks_is_working(self) -> None:
        t = thread(status="completed", pendingBackgroundTasks=[{"kind": "x"}])
        self.assertEqual(classify(t, NOW_MS), "working")

    def test_unread_failure_is_blocked(self) -> None:
        t = thread(
            status="failed",
            latestRunCompletedAt="2026-10-23T15:00:00.000Z",
            lastVisitedAt="2026-10-23T14:00:00.000Z",
        )
        self.assertEqual(classify(t, NOW_MS), "blocked")

    def test_read_failure_is_idle(self) -> None:
        t = thread(
            status="failed",
            latestRunCompletedAt="2026-10-23T14:00:00.000Z",
            lastVisitedAt="2026-10-23T15:00:00.000Z",
        )
        self.assertEqual(classify(t, NOW_MS), "idle")

    def test_unread_completion_is_done(self) -> None:
        t = thread(
            status="completed",
            latestRunCompletedAt="2026-10-23T15:00:00.000Z",
        )
        self.assertEqual(classify(t, NOW_MS), "done")

    def test_unread_completion_subagent_is_idle(self) -> None:
        t = thread(
            status="completed",
            latestRunCompletedAt="2026-10-23T15:00:00.000Z",
            lineage={"relationshipToParent": "subagent", "rootThreadId": "r"},
        )
        self.assertEqual(classify(t, NOW_MS), "idle")

    def test_order_pending_beats_running(self) -> None:
        t = thread(
            status="running",
            activityRunStatus="running",
            pendingRuntimeRequest={"kind": "question"},
        )
        self.assertEqual(classify(t, NOW_MS), "blocked")

    def test_order_working_beats_unread_done(self) -> None:
        t = thread(
            status="running",
            latestRunCompletedAt="2026-10-23T15:00:00.000Z",
        )
        self.assertEqual(classify(t, NOW_MS), "working")

    def test_usage_limited_is_idle(self) -> None:
        self.assertEqual(classify(thread(status="usage-limited"), NOW_MS), "idle")

    def test_unread_logic(self) -> None:
        self.assertFalse(unread(thread()))
        self.assertTrue(
            unread(thread(latestRunCompletedAt="2026-10-23T15:00:00.000Z"))
        )
        self.assertFalse(
            unread(
                thread(
                    latestRunCompletedAt="not-a-date",
                    lastVisitedAt="2026-10-23T15:00:00.000Z",
                )
            )
        )

    def test_unread_respects_visit_and_settlement_timestamps(self) -> None:
        before = "2026-10-23T14:00:00Z"
        completed = "2026-10-23T15:00:00Z"
        after = "2026-10-23T16:00:00Z"
        for visited, settled, expected in (
            (None, completed, False),
            (before, after, False),
            ("invalid", completed, False),
            (after, before, False),
            (completed, "invalid", False),
            (None, "2026-10-23T12:00:00-03:00", False),
            (before, before, True),
            (None, "invalid", True),
            (None, None, True),
        ):
            with self.subTest(visited=visited, settled=settled):
                self.assertEqual(unread(thread(
                    latestRunCompletedAt=completed,
                    lastVisitedAt=visited, settledAt=settled,
                )), expected)


class VisibilityTests(unittest.TestCase):
    def store_with(self, *threads: dict[str, object]) -> ShellStore:
        store = ShellStore()
        for t in threads:
            store.threads[str(t["id"])] = t
        return store

    def test_snoozed_future_hidden(self) -> None:
        t = thread(
            id="a",
            status="running",
            snoozedUntil="2026-10-24T00:00:00.000Z",
        )
        visible, _ = visible_threads(self.store_with(t), NOW_MS)
        self.assertEqual(visible, [])

    def test_settled_done_hidden(self) -> None:
        t = thread(
            id="a",
            status="completed",
            settledAt="2026-10-23T15:00:00.000Z",
            latestRunCompletedAt="2026-10-23T15:00:00.000Z",
        )
        visible, _ = visible_threads(self.store_with(t), NOW_MS)
        self.assertEqual(visible, [])

    def test_settled_working_kept(self) -> None:
        t = thread(id="a", status="running", settledAt="2026-10-23T15:00:00.000Z")
        visible, _ = visible_threads(self.store_with(t), NOW_MS)
        self.assertEqual([row["id"] for row in visible], ["a"])

    def test_subagent_idle_hidden(self) -> None:
        t = thread(
            id="a",
            status="completed",
            lineage={"relationshipToParent": "subagent"},
            latestRunCompletedAt="2026-10-23T15:00:00.000Z",
        )
        visible, _ = visible_threads(self.store_with(t), NOW_MS)
        # completed+unread+subagent classifies idle -> hidden
        self.assertEqual(visible, [])

    def test_subagent_working_kept(self) -> None:
        t = thread(
            id="a",
            status="running",
            lineage={"relationshipToParent": "subagent"},
        )
        visible, _ = visible_threads(self.store_with(t), NOW_MS)
        self.assertEqual([row["id"] for row in visible], ["a"])

    def test_unvisited_failed_subagent_stays_hidden(self) -> None:
        # Regression: subagent threads are never visited by the user
        # (lastVisitedAt stays at creation), so an unread failure used to pin
        # an orange "needs you" row in the dock forever, resurfacing after
        # every snooze expired.
        t = thread(
            id="s",
            status="failed",
            lastErrorCode="api_error_429",
            lastErrorClass="usage_limit",
            lineage={"relationshipToParent": "subagent"},
            latestRunCompletedAt="2026-10-23T15:00:00.000Z",
            lastVisitedAt="2026-10-23T14:00:00.000Z",
        )
        visible, _ = visible_threads(self.store_with(t), NOW_MS)
        self.assertEqual(visible, [])

    def test_idle_old_hidden_idle_recent_kept(self) -> None:
        old = thread(id="old", status="stopped", updatedAt="2026-10-20T00:00:00.000Z")
        new = thread(id="new", status="stopped", updatedAt="2026-10-23T16:00:00.000Z")
        visible, _ = visible_threads(self.store_with(old, new), NOW_MS)
        self.assertEqual([row["id"] for row in visible], ["new"])

    def test_idle_pinned_kept(self) -> None:
        t = thread(
            id="a", status="stopped", updatedAt="2026-10-20T00:00:00.000Z",
            pinnedAt="2026-10-21T00:00:00.000Z",
        )
        visible, _ = visible_threads(self.store_with(t), NOW_MS)
        self.assertEqual([row["id"] for row in visible], ["a"])

    def test_sort_blocked_first_then_updated(self) -> None:
        a = thread(id="a", status="running", updatedAt="2026-10-23T10:00:00.000Z")
        b = thread(
            id="b", status="failed",
            latestRunCompletedAt="2026-10-23T15:00:00.000Z",
            lastVisitedAt="2026-10-23T14:00:00.000Z",
            updatedAt="2026-10-23T09:00:00.000Z",
        )
        c = thread(id="c", status="running", updatedAt="2026-10-23T16:00:00.000Z")
        visible, truncated = visible_threads(self.store_with(a, b, c), NOW_MS)
        self.assertFalse(truncated)
        self.assertEqual([row["id"] for row in visible], ["b", "c", "a"])

    def test_cap_64_truncates(self) -> None:
        threads = [
            thread(id=f"t-{i:03d}", status="running",
                   updatedAt="2026-10-23T16:00:00.000Z")
            for i in range(70)
        ]
        visible, truncated = visible_threads(self.store_with(*threads), NOW_MS)
        self.assertTrue(truncated)
        self.assertEqual(len(visible), 64)


class StoreTests(unittest.TestCase):
    def test_sequence_dedupe(self) -> None:
        store = ShellStore()
        item = {
            "kind": "thread.updated",
            "sequence": 10,
            "thread": thread(id="a", status="running"),
        }
        store.apply(item)
        store.apply(item)
        store.apply({"kind": "thread.updated", "sequence": 9,
                     "thread": thread(id="a", status="failed")})
        self.assertEqual(store.sequence, 10)
        self.assertEqual(store.threads["a"]["status"], "running")

    def test_snapshot_replace(self) -> None:
        store = ShellStore()
        store.apply({
            "kind": "snapshot",
            "snapshot": {
                "schemaVersion": 2,
                "snapshotSequence": 5,
                "projects": [{"id": "p1", "title": "P1"}],
                "threads": [thread(id="a", projectId="p1", status="running")],
            },
        })
        self.assertEqual(store.sequence, 5)
        self.assertEqual(set(store.threads), {"a"})
        store.apply({
            "kind": "snapshot",
            "snapshot": {
                "schemaVersion": 2,
                "snapshotSequence": 7,
                "projects": [{"id": "p2", "title": "P2"}],
                "threads": [],
            },
        })
        self.assertEqual(store.sequence, 7)
        self.assertEqual(store.threads, {})
        self.assertEqual(set(store.projects), {"p2"})

    def test_snapshot_bad_schema_rejected(self) -> None:
        store = ShellStore()
        with self.assertRaises(t3model.Failure):
            store.apply({"kind": "snapshot", "snapshot": {"schemaVersion": 1}})

    def test_archived_thread_dropped(self) -> None:
        store = ShellStore()
        store.apply({
            "kind": "snapshot",
            "snapshot": {
                "schemaVersion": 2,
                "snapshotSequence": 1,
                "projects": [],
                "threads": [thread(id="a", archivedAt="2026-10-23T00:00:00Z")],
            },
        })
        self.assertEqual(store.threads, {})

    def test_enrichment_preserves_threads_and_sequence(self) -> None:
        for start_seq in (2, 9):
            with self.subTest(start_seq=start_seq):
                store = ShellStore()
                store.apply({
                    "kind": "snapshot",
                    "snapshot": {
                        "schemaVersion": 2,
                        "snapshotSequence": start_seq,
                        "projects": [{"id": "p1", "title": "Old"}],
                        "threads": [thread(id="keep", projectId="p1",
                                           status="running")],
                    },
                })
                store.apply({"kind": "synchronized"})
                store.apply({
                    "kind": "snapshot",
                    "resolvedRepositoryIdentityRoots": ["root-1"],
                    "snapshot": {
                        "schemaVersion": 2,
                        "snapshotSequence": start_seq + 50,
                        "projects": [{"id": "p1", "title": "New"}],
                        "threads": [],
                    },
                })
                self.assertEqual(store.sequence, start_seq)
                self.assertEqual(set(store.threads), {"keep"})
                self.assertEqual(store.projects["p1"]["title"], "New")
                self.assertTrue(store.synchronized)

    def test_thread_removed_and_project_ops(self) -> None:
        store = ShellStore()
        store.apply({"kind": "thread.updated", "sequence": 1,
                     "thread": thread(id="a")})
        store.apply({"kind": "thread.removed", "sequence": 2, "threadId": "a"})
        self.assertEqual(store.threads, {})
        store.apply({"kind": "project.updated", "sequence": 3,
                     "project": {"id": "p", "title": "P"}})
        self.assertIn("p", store.projects)
        store.apply({"kind": "project.removed", "sequence": 4, "projectId": "p"})
        self.assertEqual(store.projects, {})

    def test_unknown_kind_ignored(self) -> None:
        store = ShellStore()
        store.apply({"kind": "something.new", "sequence": 3})
        self.assertEqual(store.sequence, 3)
        self.assertEqual(store.threads, {})

    def test_load_http_snapshot(self) -> None:
        store = ShellStore()
        body = json.loads((FIXTURES / "shell-snapshot.json").read_text())
        store.load_http_snapshot(body)
        self.assertEqual(store.sequence, body["snapshotSequence"])
        self.assertEqual(len(store.threads), len(body["threads"]))
        self.assertEqual(len(store.projects), len(body["projects"]))


class SnapshotTests(unittest.TestCase):
    def test_project_icon_tracks_project_updates(self) -> None:
        store = ShellStore()
        store.threads["a"] = thread(id="a", projectId="p", status="running")
        store.projects["p"] = {"id": "p", "title": "ComfyUI",
                               "projectIcon": {"kind": "emoji", "emoji": "🎨"}}
        first = live_snapshot(store)
        self.assertEqual(first["agents"][0].get("projectIcon"),
                         {"kind": "emoji", "emoji": "🎨"})
        store.apply({"kind": "project.updated", "sequence": 1, "project": {
            "id": "p", "title": "ComfyUI",
            "projectIcon": {"kind": "monogram", "text": "CU", "color": "blue"},
        }})
        second = live_snapshot(store)
        self.assertEqual(second["agents"][0]["projectIcon"],
                         {"kind": "monogram", "text": "CU", "color": "blue"})
        self.assertNotEqual(snapshot_fingerprint(first), snapshot_fingerprint(second))

    def test_schema_key_sets(self) -> None:
        store = ShellStore()
        body = json.loads((FIXTURES / "shell-snapshot.json").read_text())
        store.load_http_snapshot(body)
        store.synchronized = True
        snapshot = live_snapshot(store)
        self.assertEqual(
            sorted(snapshot.keys()),
            ["agents", "attention", "capabilities", "completeness",
             "liveCounts", "providerEpoch", "revision", "schemaVersion",
             "servers", "windowProcesses"],
        )
        self.assertEqual(snapshot["schemaVersion"], 1)
        self.assertEqual(
            snapshot["capabilities"],
            {"inventory": True, "attention": True, "remote": False,
             "actions": True, "desktopNotifications": False},
        )
        server = snapshot["servers"][0]
        self.assertEqual(
            sorted(server.keys()),
            ["capabilities", "clients", "connected", "connectionGeneration",
             "health", "host", "id", "label", "lastSnapshotObservedMs",
             "product", "session", "sessions", "source", "transport"],
        )
        self.assertNotIn("version", server)
        self.assertEqual(server["source"], "t3")
        for agent in snapshot["agents"]:
            self.assertEqual(
                sorted(agent.keys()),
                ["agent", "connectionGeneration", "host", "id", "live",
                 "observedAgeMs", "paneId", "projectIcon", "serverId", "session", "stateChangeSeq",
                 "status", "tabId", "tabTitle", "title", "transport",
                 "workspaceId", "workspaceLabel"],
            )
            self.assertTrue(agent["id"].startswith("t3:env-1:1:"))
        self.assertEqual(
            snapshot["completeness"],
            {"state": "complete", "truncated": False,
             "serverTruncated": False, "agentTruncated": False},
        )
        self.assertIsNotNone(snapshot["liveCounts"])

    def test_non_live_snapshot_withholds_cached_inventory(self) -> None:
        store = ShellStore()
        store.apply({"kind": "thread.updated", "sequence": 1,
                     "thread": thread(id="w", status="running")})
        store.apply({"kind": "thread.updated", "sequence": 2,
                     "thread": thread(id="b", status="failed",
                                      latestRunCompletedAt="2026-10-23T15:00:00Z")})
        store.apply({"kind": "thread.updated", "sequence": 3,
                     "thread": thread(id="d", status="completed",
                                      latestRunCompletedAt="2026-10-23T15:00:00Z")})
        store.synchronized = True
        for health in ("connecting", "unavailable"):
            with self.subTest(health=health):
                snapshot = live_snapshot(
                    store, health=health, error_code="server_not_running",
                    inventory_live=False,
                )
                self.assertEqual(snapshot["agents"], [])
                self.assertEqual(snapshot["attention"], [])
                self.assertIsNone(snapshot["liveCounts"])
                self.assertEqual(snapshot["completeness"]["state"], "unknown")
                self.assertFalse(snapshot["completeness"]["truncated"])
                self.assertIn("errorCode", snapshot["servers"][0])

    def test_new_subscription_waits_for_sync(self) -> None:
        store = ShellStore()
        store.apply({"kind": "thread.updated", "sequence": 4,
                     "thread": thread(id="w", status="running")})
        snapshot = live_snapshot(store, inventory_live=False)
        self.assertEqual(snapshot["agents"], [])
        store.synchronized = True
        snapshot = live_snapshot(store, inventory_live=True)
        self.assertEqual(len(snapshot["agents"]), 1)

    def test_attention_only_blocked_done(self) -> None:
        store = ShellStore()
        store.apply({"kind": "thread.updated", "sequence": 1,
                     "thread": thread(id="w", status="running")})
        store.apply({"kind": "thread.updated", "sequence": 2,
                     "thread": thread(id="b", status="failed",
                                      latestRunCompletedAt="2026-10-23T15:00:00Z")})
        store.synchronized = True
        snapshot = live_snapshot(store)
        attention = {row["paneId"]: row["status"] for row in snapshot["attention"]}
        self.assertEqual(attention, {"b": "blocked"})
        counts = snapshot["liveCounts"]
        self.assertEqual(counts["working"], 1)
        self.assertEqual(counts["blocked"], 1)
        self.assertEqual(counts["agents"], 2)
        self.assertEqual(counts["servers"], 1)
        self.assertEqual(counts["unknown"], 0)

    def test_failure_attention_tracks_settlement(self) -> None:
        subagent = {"relationshipToParent": "subagent"}
        blocked = {"failure": "blocked"}
        for lineage, settled, expected in (
            # Root failures need the user until visited or settled.
            (None, "2026-10-23T15:00:00Z", {}),
            (None, "2026-10-23T16:00:00Z", {}),
            (None, "2026-10-23T14:00:00Z", blocked),
            (None, "invalid", blocked),
            (None, None, blocked),
            # Subagent failures never do: the parent run reports them, and a
            # subagent thread is never visited, so honouring them keeps a
            # permanent "needs you" dot that survives every snooze.
            (subagent, "2026-10-23T15:00:00Z", {}),
            (subagent, "2026-10-23T14:00:00Z", {}),
            (subagent, None, {}),
        ):
            with self.subTest(lineage=lineage, settled=settled):
                store = ShellStore()
                store.threads["failure"] = thread(
                    id="failure", status="failed", lineage=lineage,
                    latestRunCompletedAt="2026-10-23T15:00:00Z",
                    settledAt=settled,
                )
                snapshot = live_snapshot(store)
                for key in ("agents", "attention"):
                    self.assertEqual(
                        {row["paneId"]: row["status"] for row in snapshot[key]},
                        expected,
                    )
                self.assertEqual(snapshot["liveCounts"]["blocked"], len(expected))
                self.assertEqual(snapshot["liveCounts"]["agents"], len(expected))

    def test_unread_failure_subagent_is_idle(self) -> None:
        t = thread(
            status="failed",
            latestRunCompletedAt="2026-10-23T15:00:00.000Z",
            lastVisitedAt="2026-10-23T14:00:00.000Z",
            lineage={"relationshipToParent": "subagent", "rootThreadId": "r"},
        )
        self.assertEqual(classify(t, NOW_MS), "idle")

    def test_settlement_does_not_hide_active_subagent_work(self) -> None:
        for active, status in (
            ({"pendingRuntimeRequest": {"kind": "approval"}}, "blocked"),
            ({"hasActionableProposedPlan": True}, "blocked"),
            ({"status": "running"}, "working"),
            ({"activityRunStatus": "running"}, "working"),
            ({"pendingBackgroundTasks": [{"kind": "task"}]}, "working"),
        ):
            with self.subTest(active=active):
                store = ShellStore()
                t = thread(
                    id="active", status="failed",
                    latestRunCompletedAt="2026-10-23T15:00:00Z",
                    settledAt="2026-10-23T16:00:00Z",
                    lineage={"relationshipToParent": "subagent"},
                )
                t.update(active)
                store.threads["active"] = t
                snapshot = live_snapshot(store)
                self.assertEqual(
                    [(row["paneId"], row["status"]) for row in snapshot["agents"]],
                    [("active", status)],
                )
                self.assertEqual(snapshot["liveCounts"][status], 1)
                self.assertEqual(len(snapshot["attention"]), int(status == "blocked"))

    def test_state_change_seq_stable_until_status_changes(self) -> None:
        store = ShellStore()
        tracker = StatusTracker()
        state = live_state()
        store.apply({"kind": "thread.updated", "sequence": 1,
                     "thread": thread(id="w", status="running")})
        first = build_snapshot(state, store, tracker)
        seq_first = first["agents"][0]["stateChangeSeq"]
        state_later = live_state(now_ms=NOW_MS + 60000)
        second = build_snapshot(state_later, store, tracker)
        self.assertEqual(second["agents"][0]["stateChangeSeq"], seq_first)
        store.apply({"kind": "thread.updated", "sequence": 2,
                     "thread": thread(id="w", status="failed",
                                      latestRunCompletedAt="2026-10-23T15:00:00Z")})
        third = build_snapshot(live_state(now_ms=NOW_MS + 120000), store, tracker)
        self.assertNotEqual(third["agents"][0]["stateChangeSeq"], seq_first)

    def test_churn_fingerprint_ignores_ages(self) -> None:
        store = ShellStore()
        store.apply({"kind": "thread.updated", "sequence": 1,
                     "thread": thread(id="w", status="running")})
        tracker = StatusTracker()
        first = build_snapshot(live_state(), store, tracker)
        fp_first = snapshot_fingerprint(first)
        for step in range(50):
            store.apply({"kind": "thread.updated", "sequence": 2 + step,
                         "thread": thread(id="w", status="running",
                                          updatedAt="2026-10-23T16:00:00.000Z")})
            snapshot = build_snapshot(live_state(now_ms=NOW_MS + step * 1000), store,
                                      tracker)
            self.assertEqual(snapshot_fingerprint(snapshot), fp_first)

    def test_agent_kind_mapping(self) -> None:
        self.assertEqual(agent_kind(thread(providerInstanceId="Codex-Native")), "codex")
        self.assertEqual(agent_kind(thread(providerInstanceId="ANTHROPIC-CLAUDE")), "claude")
        self.assertEqual(
            agent_kind(thread(providerInstanceId="", modelSelection={"provider": "Cursor"})),
            "cursor",
        )
        self.assertEqual(agent_kind(thread(providerInstanceId="my-opencode-x")), "opencode")
        self.assertEqual(agent_kind(thread(providerInstanceId="Other Thing")), "other thing")

    def test_clean_text(self) -> None:
        self.assertEqual(clean_text("a\x00b\x7fc  d"), "abc d")
        self.assertEqual(clean_text("x" * 500), "x" * 200)
        self.assertEqual(clean_text(None), "")

    def test_frame_cap_fallback(self) -> None:
        store = ShellStore()
        store.apply({"kind": "thread.updated", "sequence": 1,
                     "thread": thread(id="w", status="running", title="x" * 5000)})
        snapshot = live_snapshot(store)
        frame = finalize_snapshot(snapshot)
        self.assertLessEqual(len(frame), 1024 * 1024)
        if b"normalized_output_too_large" in frame:
            compact = json.loads(frame.decode("utf-8"))
            self.assertEqual(compact["agents"], [])
            self.assertIsNone(compact["liveCounts"])

    def test_unpaired_placeholder(self) -> None:
        store = ShellStore()
        snapshot = build_snapshot(
            BuildState(epoch="e", revision=1, server_id="t3:unpaired",
                       health="unavailable", error_code="pairing_required",
                       generation=1, now_ms=NOW_MS),
            store,
            StatusTracker(),
        )
        server = snapshot["servers"][0]
        self.assertEqual(server["id"], "t3:unpaired")
        self.assertEqual(server["errorCode"], "pairing_required")
        self.assertEqual(snapshot["agents"], [])
        self.assertEqual(snapshot["completeness"]["state"], "unknown")


if __name__ == "__main__":
    unittest.main()
