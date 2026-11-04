# SPDX-License-Identifier: Apache-2.0
"""T3 shell state: store, classification and Herdr-schema snapshot builder.

The provider speaks the Herdr provider contract (schema v1) so the existing
``DockHerdrService``/``DockHerdrWindowAgents`` stack consumes T3 threads
without modification.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import json
from datetime import datetime, timezone
from typing import Any

from t3icons import project_icon

SCHEMA_VERSION = 1
SHELL_SCHEMA_VERSION = 2
MAX_VISIBLE_THREADS = 64
MAX_OUTPUT_FRAME = 1024 * 1024

WORKING_ACTIVITY = ("preparing", "starting", "running", "waiting")
WORKING_STATUS = ("queued", "preparing", "starting", "running", "waiting")
STATUS_RANK = {"blocked": 0, "working": 1, "done": 2, "idle": 3}
DAY_MS = 24 * 60 * 60 * 1000


class Failure(Exception):
    """Model failure carrying a short machine-readable code."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def _parse_ms(value: object) -> int | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    try:
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=timezone.utc)
        return int(moment.timestamp() * 1000)
    except (ValueError, OverflowError, OSError):
        return None


def clean_text(value: object, maximum: int = 200) -> str:
    """Strip controls, collapse whitespace and cap length for display."""
    if not isinstance(value, str):
        return ""
    cleaned = "".join(
        char
        for char in value
        if ord(char) >= 32 and ord(char) != 127
        and not 0xD800 <= ord(char) <= 0xDFFF
    )
    return " ".join(cleaned.split())[:maximum]


def _is_subagent(thread: dict[str, Any]) -> bool:
    lineage = thread.get("lineage")
    return (
        isinstance(lineage, dict)
        and lineage.get("relationshipToParent") == "subagent"
    )


def unread(thread: dict[str, Any]) -> bool:
    """True when the latest completion has not been visited or settled."""
    completed = thread.get("latestRunCompletedAt")
    if not isinstance(completed, str) or not completed:
        return False
    completed_ms = _parse_ms(completed)
    if completed_ms is None:
        return False
    for field in ("lastVisitedAt", "settledAt"):
        acknowledged_ms = _parse_ms(thread.get(field))
        if acknowledged_ms is not None and acknowledged_ms >= completed_ms:
            return False
    return True


def classify(thread: dict[str, Any], now_ms: int) -> str:
    """Map a T3 thread to the Herdr status enum (first match wins)."""
    _ = now_ms
    pending = thread.get("pendingRuntimeRequest")
    if isinstance(pending, dict) and pending.get("kind"):
        return "blocked"
    if thread.get("hasActionableProposedPlan") is True:
        return "blocked"
    if thread.get("activityRunStatus") in WORKING_ACTIVITY:
        return "working"
    if thread.get("status") in WORKING_STATUS:
        return "working"
    background = thread.get("pendingBackgroundTasks")
    if isinstance(background, list) and len(background) > 0:
        return "working"
    if (
        thread.get("status") == "failed"
        and unread(thread)
        and not _is_subagent(thread)
    ):
        # A subagent failure is the parent run's to report: subagent threads
        # are never visited by the user (lastVisitedAt stays at creation), so
        # honouring them here would keep a "needs you" dot forever.
        return "blocked"
    if (
        thread.get("status") == "completed"
        and unread(thread)
        and not _is_subagent(thread)
    ):
        return "done"
    return "idle"


def _valid_thread(thread: object) -> bool:
    if not isinstance(thread, dict):
        return False
    if not isinstance(thread.get("id"), str) or not thread["id"]:
        return False
    if thread.get("archivedAt"):
        return False
    if thread.get("deletedAt"):
        return False
    return True


class ShellStore:
    """Incremental T3 shell state fed by stream items or HTTP snapshots."""

    def __init__(self) -> None:
        self.projects: dict[str, dict[str, Any]] = {}
        self.threads: dict[str, dict[str, Any]] = {}
        self.sequence: int = -1
        self.synchronized: bool = False

    def apply(self, item: dict[str, Any]) -> None:
        """Apply one stream item (``kind`` dispatches the update)."""
        if not isinstance(item, dict):
            return
        kind = item.get("kind")
        if kind == "synchronized":
            self.synchronized = True
            return
        if kind == "snapshot":
            self._apply_snapshot(item)
            return
        sequence = item.get("sequence")
        if isinstance(sequence, int) and not isinstance(sequence, bool):
            if sequence <= self.sequence:
                return
            self.sequence = sequence
        if kind == "thread.updated":
            thread = item.get("thread")
            thread_id = thread.get("id") if isinstance(thread, dict) else None
            if _valid_thread(thread):
                assert isinstance(thread, dict) and isinstance(thread_id, str)
                self.threads[thread_id] = thread
            elif isinstance(thread_id, str) and thread_id:
                self.threads.pop(thread_id, None)
        elif kind == "thread.removed":
            thread_id = item.get("threadId")
            if isinstance(thread_id, str):
                self.threads.pop(thread_id, None)
        elif kind == "project.updated":
            project = item.get("project")
            project_id = project.get("id") if isinstance(project, dict) else None
            if isinstance(project, dict) and isinstance(project_id, str) and project_id:
                self.projects[project_id] = project
        elif kind == "project.removed":
            project_id = item.get("projectId")
            if isinstance(project_id, str):
                self.projects.pop(project_id, None)

    def _apply_snapshot(self, item: dict[str, Any]) -> None:
        snap = item.get("snapshot")
        if not isinstance(snap, dict):
            raise Failure("unsupported")
        if snap.get("schemaVersion") != SHELL_SCHEMA_VERSION:
            raise Failure("unsupported")
        enrichment = item.get("resolvedRepositoryIdentityRoots")
        if isinstance(enrichment, list):
            projects = snap.get("projects")
            if isinstance(projects, list):
                for project in projects:
                    if (
                        isinstance(project, dict)
                        and isinstance(project.get("id"), str)
                        and project["id"]
                    ):
                        self.projects[project["id"]] = project
            return
        snapshot_sequence = snap.get("snapshotSequence")
        projects: dict[str, dict[str, Any]] = {}
        threads: dict[str, dict[str, Any]] = {}
        raw_projects = snap.get("projects")
        if isinstance(raw_projects, list):
            for project in raw_projects:
                if (
                    isinstance(project, dict)
                    and isinstance(project.get("id"), str)
                    and project["id"]
                ):
                    projects[project["id"]] = project
        raw_threads = snap.get("threads")
        if isinstance(raw_threads, list):
            for thread in raw_threads:
                if _valid_thread(thread):
                    assert isinstance(thread, dict)
                    thread_id = thread["id"]
                    assert isinstance(thread_id, str)
                    threads[thread_id] = thread
        self.projects = projects
        self.threads = threads
        if (
            isinstance(snapshot_sequence, int)
            and not isinstance(snapshot_sequence, bool)
        ):
            self.sequence = snapshot_sequence

    def load_http_snapshot(self, body: dict[str, Any]) -> None:
        """Load a ``GET /api/orchestration/shell`` body as a snapshot item."""
        self.apply({"kind": "snapshot", "snapshot": body})


def visible_threads(
    store: ShellStore, now_ms: int
) -> tuple[list[dict[str, Any]], bool]:
    """Filter, sort and cap visible threads; report truncation."""
    ranked: list[tuple[int, int, str, dict[str, Any]]] = []
    for thread in store.threads.values():
        status = classify(thread, now_ms)
        snoozed = _parse_ms(thread.get("snoozedUntil"))
        if snoozed is not None and snoozed > now_ms:
            continue
        if thread.get("settledAt") and status not in ("blocked", "working"):
            continue
        if _is_subagent(thread):
            if status not in ("blocked", "working"):
                continue
        else:
            if status == "idle":
                if not thread.get("pinnedAt"):
                    updated = _parse_ms(thread.get("updatedAt"))
                    if updated is None or now_ms - updated > DAY_MS:
                        continue
        updated = _parse_ms(thread.get("updatedAt"))
        ranked.append(
            (STATUS_RANK[status], -(updated or 0), str(thread.get("id")), thread)
        )
    ranked.sort(key=lambda row: (row[0], row[1], row[2]))
    truncated = len(ranked) > MAX_VISIBLE_THREADS
    return [row[3] for row in ranked[:MAX_VISIBLE_THREADS]], truncated


def agent_kind(thread: dict[str, Any]) -> str:
    """Map a thread to a display agent kind, mirroring Herdr kinds."""
    provider = thread.get("providerInstanceId")
    if not isinstance(provider, str) or not provider:
        selection = thread.get("modelSelection")
        provider = selection.get("provider") if isinstance(selection, dict) else ""
    provider = provider.lower() if isinstance(provider, str) else ""
    for needle in ("codex", "claude", "cursor", "opencode"):
        if needle in provider:
            return needle
    return provider


class StatusTracker:
    """Per-thread status-change memory for stateChangeSeq/observedAgeMs."""

    def __init__(self) -> None:
        self.entries: dict[str, dict[str, int | str]] = {}

    def observe(self, thread_id: str, status: str, now_ms: int) -> tuple[str, int]:
        """Return ``(stateChangeSeq, observedAgeMs)`` for a thread status."""
        entry = self.entries.get(thread_id)
        if entry is None or entry.get("status") != status:
            sequence = int(entry.get("seq", 0)) + 1 if entry else 1
            entry = {"status": status, "changedAtMs": now_ms, "seq": sequence}
            self.entries[thread_id] = entry
        changed_at = int(entry["changedAtMs"])
        return str(entry["seq"]), max(0, now_ms - changed_at)

    def prune(self, thread_ids: set[str]) -> None:
        """Drop memory for threads that are no longer visible."""
        for thread_id in list(self.entries):
            if thread_id not in thread_ids:
                del self.entries[thread_id]


@dataclass
class BuildState:
    """Everything :func:`build_snapshot` needs besides the store."""

    epoch: str
    revision: int
    server_id: str
    health: str  # "live" | "connecting" | "unavailable"
    error_code: str | None
    generation: int
    clients: list[dict[str, Any]] = field(default_factory=list)
    inventory_live: bool = False  # synchronized stream or HTTP fallback loaded
    wp_revision: int = 0
    wp_identities: list[dict[str, int]] = field(default_factory=list)
    now_ms: int = 0
    last_snapshot_observed_ms: int | None = None


def _server_row(state: BuildState) -> dict[str, Any]:
    row: dict[str, Any] = {
        "id": state.server_id,
        "source": "t3",
        "product": "T3 Code",
        "transport": "local",
        "host": "local",
        "sessions": [],
        "session": "",
        "label": "T3 Code",
        "capabilities": {"focusAgent": True},
        "connectionGeneration": state.generation,
        "health": state.health,
        "connected": state.health == "live",
        "lastSnapshotObservedMs": state.last_snapshot_observed_ms,
        "clients": list(state.clients),
    }
    if state.health != "live" and state.error_code:
        row["errorCode"] = state.error_code
    return row


def build_snapshot(
    state: BuildState, store: ShellStore, tracker: StatusTracker
) -> dict[str, Any]:
    """Build a Herdr-schema-v1 snapshot for the current T3 state."""
    live = state.health == "live" and state.inventory_live
    agents: list[dict[str, Any]] = []
    attention: list[dict[str, Any]] = []
    counts: dict[str, Any] | None = None
    agent_truncated = False
    if live:
        visible, agent_truncated = visible_threads(store, state.now_ms)
        seen: set[str] = set()
        for thread in visible:
            thread_id = str(thread.get("id"))
            seen.add(thread_id)
            status = classify(thread, state.now_ms)
            seq, age_ms = tracker.observe(thread_id, status, state.now_ms)
            project_id = thread.get("projectId")
            project = (
                store.projects.get(project_id)
                if isinstance(project_id, str)
                else None
            )
            project_title = ""
            if isinstance(project, dict):
                title = project.get("title") or project.get("name")
                if isinstance(title, str):
                    project_title = clean_text(title)
            title = clean_text(thread.get("title")) or "Untitled thread"
            if _is_subagent(thread):
                title = f"Subagent: {title}"
            agents.append(
                {
                    "id": f"{state.server_id}:{state.generation}:{thread_id}",
                    "serverId": state.server_id,
                    "connectionGeneration": state.generation,
                    "transport": "local",
                    "host": "local",
                    "session": "",
                    "paneId": thread_id,
                    "status": status,
                    "live": True,
                    "workspaceId": project_id if isinstance(project_id, str) else "",
                    "workspaceLabel": project_title,
                    "projectIcon": project_icon(project),
                    "tabId": project_id if isinstance(project_id, str) else "",
                    "tabTitle": project_title,
                    "title": title,
                    "agent": agent_kind(thread),
                    "stateChangeSeq": seq,
                    "observedAgeMs": age_ms,
                }
            )
            if status in ("blocked", "done"):
                attention.append(
                    {
                        "agentId": f"{state.server_id}:{state.generation}:{thread_id}",
                        "serverId": state.server_id,
                        "session": "",
                        "paneId": thread_id,
                        "status": status,
                    }
                )
        tracker.prune(seen)
        counts = {
            "blocked": 0,
            "done": 0,
            "working": 0,
            "idle": 0,
            "unknown": 0,
            "agents": len(agents),
            "servers": 1,
            "complete": not agent_truncated,
        }
        for agent in agents:
            counts[agent["status"]] += 1
    completeness_state = "unknown" if not live else ("partial" if agent_truncated else "complete")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "providerEpoch": state.epoch,
        "revision": state.revision,
        "capabilities": {
            "inventory": True,
            "attention": True,
            "remote": False,
            "actions": True,
            "desktopNotifications": False,
        },
        "servers": [_server_row(state)],
        "agents": agents,
        "attention": attention,
        "liveCounts": counts,
        "completeness": {
            "state": completeness_state,
            "truncated": agent_truncated,
            "serverTruncated": False,
            "agentTruncated": agent_truncated,
        },
        "windowProcesses": {
            "revision": state.wp_revision,
            "identities": list(state.wp_identities),
        },
    }


def snapshot_fingerprint(snapshot: dict[str, Any]) -> str:
    """Hash a snapshot excluding churn fields (revision/ages/timestamps)."""
    redacted = json.loads(json.dumps(snapshot))
    redacted.pop("revision", None)
    for agent in redacted.get("agents", []):
        if isinstance(agent, dict):
            agent.pop("observedAgeMs", None)
    for server in redacted.get("servers", []):
        if isinstance(server, dict):
            server.pop("lastSnapshotObservedMs", None)
    canonical = json.dumps(redacted, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def finalize_snapshot(snapshot: dict[str, Any]) -> bytes:
    """Serialize one NDJSON frame, applying the 1 MiB fallback when needed."""
    frame = (
        json.dumps(snapshot, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
        + "\n"
    ).encode("utf-8")
    if len(frame) > MAX_OUTPUT_FRAME:
        snapshot["agents"] = []
        snapshot["attention"] = []
        snapshot["liveCounts"] = None
        snapshot["completeness"] = {
            "state": "partial",
            "truncated": True,
            "serverTruncated": snapshot["completeness"].get("serverTruncated", False),
            "agentTruncated": True,
        }
        snapshot["sourceErrorCode"] = "normalized_output_too_large"
        frame = (
            json.dumps(snapshot, separators=(",", ":"), ensure_ascii=False) + "\n"
        ).encode("utf-8")
    if len(frame) > MAX_OUTPUT_FRAME:
        raise Failure("too_large")
    return frame
