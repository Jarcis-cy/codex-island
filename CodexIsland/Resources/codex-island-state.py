#!/usr/bin/env python3
"""
Codex Island hook helper.

- Receives Codex hooks payloads on stdin.
- Normalizes them for Codex Island.app via Unix socket.
- Uses transcript_path as the durable source of truth for later reconciliation.
"""

import json
import os
import socket
import subprocess
import sys
from datetime import datetime, timezone

SOCKET_PATH = "/tmp/codex-island.sock"
DEBUG_LOG_PATH = os.path.expanduser("~/.codex/hooks/codex-island-debug.jsonl")


def utc_timestamp():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def append_debug(record):
    try:
        with open(DEBUG_LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def get_tty():
    parent_pid = os.getppid()
    try:
        result = subprocess.run(
            ["ps", "-p", str(parent_pid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=1,
        )
        tty = result.stdout.strip()
        if tty and tty not in {"??", "-"}:
            return tty if tty.startswith("/dev/") else f"/dev/{tty}"
    except Exception:
        pass

    try:
        return os.ttyname(sys.stdin.fileno())
    except OSError:
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except OSError:
        pass
    return None


def get_terminal_context(terminal_name, cwd):
    normalized = (terminal_name or "").lower()
    if normalized != "ghostty":
        return {}, {"strategy": "unsupported_terminal"}

    script = """
tell application "Ghostty"
    set outputLines to {}
    repeat with w in every window
        set windowID to id of w as text
        repeat with t in every tab of w
            set tabID to id of t as text
            set terminalRef to focused terminal of t
            set terminalID to id of terminalRef as text
            set terminalWD to working directory of terminalRef as text
            set end of outputLines to windowID & (ASCII character 31) & tabID & (ASCII character 31) & terminalID & (ASCII character 31) & terminalWD
        end repeat
    end repeat
    set AppleScript's text item delimiters to linefeed
    set outputText to outputLines as text
    set AppleScript's text item delimiters to ""
    return outputText
end tell
"""

    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=1,
        )
        if result.returncode != 0:
            return {}, {"strategy": "ghostty_enumeration_failed", "error": result.stderr.strip() or result.stdout.strip()}
    except Exception:
        return {}, {"strategy": "ghostty_enumeration_exception"}

    normalized_cwd = normalize_path(cwd)
    candidates = []

    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        parts = line.split("\x1f")
        if len(parts) != 4:
            continue

        candidate = {
            "terminal_window_id": parts[0] or None,
            "terminal_tab_id": parts[1] or None,
            "terminal_surface_id": parts[2] or None,
            "working_directory": parts[3] or None,
        }

        if normalize_path(candidate["working_directory"]) == normalized_cwd:
            candidates.append(candidate)

    if len(candidates) == 1:
        match = candidates[0]
        return {
            "terminal_window_id": match["terminal_window_id"],
            "terminal_tab_id": match["terminal_tab_id"],
            "terminal_surface_id": match["terminal_surface_id"],
        }, {
            "strategy": "ghostty_cwd_unique_match",
            "match_count": 1,
            "matched_working_directory": match["working_directory"],
        }

    if len(candidates) > 1:
        return {}, {
            "strategy": "ghostty_cwd_ambiguous",
            "match_count": len(candidates),
        }

    return {}, {
        "strategy": "ghostty_cwd_not_found",
        "match_count": 0,
    }


def normalize_path(path):
    if not path:
        return None

    trimmed = path.strip()
    if not trimmed:
        return None

    try:
        return os.path.realpath(trimmed)
    except OSError:
        return os.path.abspath(trimmed)


def send_event(state):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())
        sock.close()
        return True
    except OSError as error:
        append_debug({
            "timestamp": utc_timestamp(),
            "stage": "socket_error",
            "error": str(error),
            "state": state,
        })
        return False


def normalize_tool_input(payload):
    tool_name = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    if isinstance(tool_input, dict):
        return tool_name, tool_input

    command = None
    if isinstance(tool_input, dict):
        command = tool_input.get("command")

    if payload.get("tool_input", {}).get("command"):
        command = payload["tool_input"]["command"]

    if command is None and payload.get("tool_input"):
        command = payload["tool_input"].get("command")

    if command is None and payload.get("command"):
        command = payload.get("command")

    if command is not None:
        return tool_name, {"command": command}

    return tool_name, {}


def main():
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    event = payload.get("hook_event_name", "")
    session_id = payload.get("session_id", "unknown")
    cwd = payload.get("cwd", "")
    transcript_path = payload.get("transcript_path")
    turn_id = payload.get("turn_id")
    tool_name, tool_input = normalize_tool_input(payload)
    terminal_name = os.environ.get("TERM_PROGRAM") or os.environ.get("TERM")

    terminal_context, terminal_context_debug = get_terminal_context(terminal_name, cwd)

    state = {
        "provider": "codex",
        "session_id": session_id,
        "cwd": cwd,
        "transcript_path": transcript_path,
        "turn_id": turn_id,
        "event": event,
        "pid": os.getppid(),
        "tty": get_tty(),
        "terminal_name": terminal_name,
    }
    state.update(terminal_context)

    if event == "SessionStart":
        state["status"] = "waiting_for_input"
    elif event == "UserPromptSubmit":
        state["status"] = "processing"
    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        state["tool_use_id"] = payload.get("tool_use_id")
    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        state["tool_use_id"] = payload.get("tool_use_id")
    elif event == "Stop":
        state["status"] = "waiting_for_input"
    else:
        state["status"] = "notification"

    sent = send_event(state)
    append_debug({
        "timestamp": utc_timestamp(),
        "stage": "hook_received",
        "event": event,
        "sent": sent,
        "payload": payload,
        "state": state,
        "env": {
            "TERM_PROGRAM": os.environ.get("TERM_PROGRAM"),
            "TERM": os.environ.get("TERM"),
            "TMUX": os.environ.get("TMUX"),
        },
        "terminal_context_debug": terminal_context_debug,
    })


if __name__ == "__main__":
    main()
