#!/usr/bin/env python3
"""Append a normalized record to ~/.agent-halo/claude-code-status.jsonl.

Concurrency: an exclusive ``fcntl.flock`` covers every append so that multiple Claude
Code processes (different windows / projects) cannot interleave half-lines.

Rotation: when the file would grow past ``ROTATE_TRIGGER_BYTES`` (~3 MB), retain only
the most recent ``ROTATE_KEEP_BYTES`` (~2 MB) of complete lines. The Swift monitor
treats truncation as a reset, so this is safe at any moment.
"""

import datetime as dt
import fcntl
import json
import os
import pathlib
import sys

ROTATE_TRIGGER_BYTES = 3 * 1024 * 1024
ROTATE_KEEP_BYTES = 2 * 1024 * 1024


def nested_get(obj, path):
    cur = obj
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
    return cur


def first_string(*values):
    for value in values:
        if isinstance(value, str) and value:
            return value
    return ""


def maybe_rotate(fh):
    """Truncate ``fh`` to the last ROTATE_KEEP_BYTES if it has grown past the trigger.

    Caller must already hold an exclusive flock on ``fh``. We rewrite in place so the
    inode does not change — Swift readers keep their FileHandle, see the new size,
    detect truncation by ``current < previous``, and reset cleanly.
    """
    fh.seek(0, os.SEEK_END)
    size = fh.tell()
    if size < ROTATE_TRIGGER_BYTES:
        return
    fh.seek(size - ROTATE_KEEP_BYTES, os.SEEK_SET)
    # Discard the partial line at the start of the kept region.
    fh.readline()
    tail = fh.read()
    fh.seek(0, os.SEEK_SET)
    fh.truncate()
    fh.write(tail)
    fh.flush()


def main():
    event = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        payload = {}

    event = first_string(
        event,
        payload.get("hook_event_name"),
        payload.get("event"),
        payload.get("eventName"),
    )
    if not event:
        return 0

    cwd = first_string(
        payload.get("cwd"),
        # workspace.current_dir is forward-compat; not present in current Claude Code docs.
        nested_get(payload, ["workspace", "current_dir"]),
        nested_get(payload, ["workspace", "cwd"]),
        os.getcwd(),
    )
    session_id = first_string(
        payload.get("session_id"),
        payload.get("sessionId"),
        payload.get("conversation_id"),
        "claude-code",
    )
    tool_name = first_string(
        payload.get("tool_name"),
        payload.get("toolName"),
        nested_get(payload, ["tool", "name"]),
    )
    notification_type = first_string(
        payload.get("type"),
        payload.get("notification_type"),
        payload.get("notificationType"),
    ) if event == "Notification" else ""
    error_text = first_string(
        payload.get("error"),
        payload.get("error_text"),
        payload.get("errorText"),
        payload.get("tool_stderr"),
    ) if event in ("StopFailure", "PostToolUseFailure") else ""
    timestamp = first_string(
        payload.get("timestamp"),
        dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    )

    record = {
        "timestamp": timestamp,
        "event": event,
        "sessionId": session_id,
        "cwd": cwd,
        "toolName": tool_name or None,
        "notificationType": notification_type or None,
        "errorText": error_text or None,
        "source": "claude-hook",
    }

    root = pathlib.Path.home() / ".agent-halo"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    status_file = root / "claude-code-status.jsonl"

    # Open in r+ so we can both append and truncate-in-place under one flock. Create
    # the file if missing.
    fd = os.open(status_file, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        with os.fdopen(fd, "r+", encoding="utf-8") as fh:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
            try:
                maybe_rotate(fh)
                fh.seek(0, os.SEEK_END)
                fh.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
                fh.flush()
                os.fsync(fh.fileno())
            finally:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
    except Exception:
        # Hook scripts must never block the user's turn — swallow IO errors.
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
