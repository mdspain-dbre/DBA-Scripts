#!/usr/bin/env python3
"""PreToolUse guard for the "CloudSQL Health Check" agent.

Hard-blocks any destructive command (deleting databases/instances, DDL/DML, or
mutating ``gcloud sql`` control-plane operations). This is the deterministic
enforcement layer that backs the agent's read-only instructions.

Contract: read a PreToolUse JSON payload on stdin, extract the command the agent
wants to run, and emit a ``deny`` decision (exit code 2) if it matches a
destructive pattern. Otherwise ``allow`` (exit code 0).
"""

import json
import re
import sys


def extract_command(payload: str) -> str:
    """Pull just the command string out of the PreToolUse payload.

    We deliberately look only at the command field (not natural-language fields
    like a terminal "explanation"/"goal") to avoid false positives.
    """
    try:
        data = json.loads(payload)
    except Exception:
        data = None

    if isinstance(data, dict):
        tool_input = (
            data.get("tool_input")
            or data.get("toolInput")
            or data.get("input")
            or {}
        )
        if isinstance(tool_input, dict):
            cmd = (
                tool_input.get("command")
                or tool_input.get("commandLine")
                or tool_input.get("cmd")
                or ""
            )
            if cmd:
                return cmd

    # Fallback: pull the first "command":"..." value out of the raw payload.
    match = re.search(r'"command"\s*:\s*"([^"]*)"', payload)
    if match:
        return match.group(1)

    # Last resort: scan the whole payload so we fail safe (block) rather than open.
    return payload


def normalize(cmd: str) -> str:
    """Lowercase and replace every non-alphanumeric character with a space.

    This makes verbs space-delimited regardless of surrounding punctuation
    (quotes, semicolons, hyphens, parentheses, newlines, ...). The result is
    padded with spaces so word-boundary matching with leading/trailing spaces
    works for tokens at the start or end of the command.
    """
    lowered = re.sub(r"[^a-z0-9]+", " ", cmd.lower())
    return f" {lowered.strip()} "


def deny(reason: str) -> None:
    """Emit a PreToolUse deny decision and exit 2 (blocking)."""
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        },
        "continue": False,
        "stopReason": reason,
    }))
    sys.exit(2)


def allow() -> None:
    """Emit a PreToolUse allow decision and exit 0."""
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
        },
    }))
    sys.exit(0)


# 1) Mutating CloudSQL control-plane operations (delete/patch/restart/etc.).
GCLOUD_SQL_MUTATION = re.compile(
    r"gcloud .*sql .*"
    r"(delete|patch|restart|failover|clone|set password|set root password|reschedule maintenance)"
)

# 2) Destructive / mutating SQL or any resource deletion (DDL + DML). Any of
#    these verbs as a standalone word blocks the command -- DROP DATABASE and
#    DELETE are explicitly forbidden, as is `gcloud ... delete`.
MUTATING_VERB = re.compile(
    r" (drop|truncate|delete|alter|update|insert|replace|grant|revoke|create|rename|merge|call) "
)


def main() -> None:
    payload = sys.stdin.read()
    scan = normalize(extract_command(payload))

    if GCLOUD_SQL_MUTATION.search(scan):
        deny(
            "Blocked: mutating gcloud sql operation. The CloudSQL Health Check "
            "agent is read-only and may not delete or change instances/databases."
        )

    if MUTATING_VERB.search(scan):
        deny(
            "Blocked: destructive/mutating operation detected (DROP/DELETE/"
            "TRUNCATE/etc.). The CloudSQL Health Check agent is read-only and may "
            "only run SELECT/SHOW/EXPLAIN queries and non-mutating gcloud reads."
        )

    allow()


if __name__ == "__main__":
    main()
