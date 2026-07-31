#!/usr/bin/env python3
"""PreToolUse guard for the "DB Fleet Health Check" agent.

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


# 1) Mutating cloud CLI resource operations (delete/patch/create/restart/etc.).
#    Matched case-insensitively on the raw command; `describe`/`list`/`get` and
#    other read verbs are deliberately absent, so read-only gcloud stays allowed.
GCLOUD_MUTATION = re.compile(
    r"\bgcloud\b.*\b("
    r"delete|remove|patch|create|update|restart|failover|clone|restore|"
    r"reset|set-password|reset-password|reschedule[-\s]?maintenance|"
    r"set\s+(?:root\s+)?password"
    r")\b",
    re.IGNORECASE | re.DOTALL,
)

# 1b) Object-store / dataset deletions that also destroy data.
STORAGE_DELETE = re.compile(
    r"\b(?:gsutil\b.*\brm\b|gcloud\s+storage\b.*\b(?:rm|delete)\b|bq\b.*\brm\b)",
    re.IGNORECASE | re.DOTALL,
)

# 2) Destructive / mutating SQL, matched ONLY in actual DDL/DML statement
#    position -- i.e. the verb is the first token of a statement. A statement
#    starts at the beginning of the string/line or immediately after a
#    separator (`;`), an opening quote (shell/SQL), or `(`. The trailing `\b`
#    means `update_time`, `create_date`, `SHOW CREATE TABLE`, `is_updatable`,
#    etc. are NOT matched -- only a leading `UPDATE`/`CREATE`/... verb is.
SQL_DESTRUCTIVE = re.compile(
    r"""(?:^|[;"'`(\n])\s*
        (drop|truncate|delete|alter|update|insert|replace|rename|merge|
         grant|revoke|create|call)
        \b""",
    re.IGNORECASE | re.MULTILINE | re.VERBOSE,
)

# 2b) `EXPLAIN ANALYZE <dml>` actually executes the statement in Postgres, so
#    treat it as destructive even though the verb isn't first.
EXPLAIN_ANALYZE_DML = re.compile(
    r"\bexplain\s+analyze\b.*\b"
    r"(update|delete|insert|truncate|drop|alter|replace|merge|create|call)\b",
    re.IGNORECASE | re.DOTALL,
)


def main() -> None:
    payload = sys.stdin.read()
    cmd = extract_command(payload)

    if GCLOUD_MUTATION.search(cmd) or STORAGE_DELETE.search(cmd):
        deny(
            "Blocked: mutating cloud CLI operation (delete/create/patch/restart/"
            "etc.). This agent is read-only and may not create, delete, or change "
            "instances, databases, clusters, or stored data."
        )

    if SQL_DESTRUCTIVE.search(cmd) or EXPLAIN_ANALYZE_DML.search(cmd):
        deny(
            "Blocked: destructive/mutating SQL detected (DROP/DELETE/TRUNCATE/"
            "ALTER/UPDATE/INSERT/etc. in statement position). This agent is "
            "read-only and may only run SELECT/SHOW/EXPLAIN and reads against "
            "information_schema/performance_schema/pg_stat_*."
        )

    allow()


if __name__ == "__main__":
    main()
