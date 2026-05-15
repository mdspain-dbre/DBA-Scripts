# MCP Toolbox — MySQL DBA Troubleshooting

Read-only MySQL diagnostic tools exposed via [MCP Toolbox for Databases](https://github.com/googleapis/genai-toolbox)
for use by an AI agent (ADK / Vertex AI Agent Engine / any MCP client).

## Prerequisites

- `gcloud` authenticated with ADC: `gcloud auth application-default login`
- A Cloud SQL for MySQL instance (or update `tools.yaml` to use the `mysql` source kind)
- A **read-only** DB user. Recommended grants:
  ```sql
  CREATE USER 'dba_readonly'@'%' IDENTIFIED BY '...';
  GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO 'dba_readonly'@'%';
  GRANT SELECT ON performance_schema.* TO 'dba_readonly'@'%';
  GRANT SELECT ON sys.*               TO 'dba_readonly'@'%';
  ```

## Install Toolbox

```bash
brew install mcp-toolbox
# or download a release binary from
# https://github.com/googleapis/genai-toolbox/releases
```

## Configure

1. Edit [tools.yaml](tools.yaml) and replace `REPLACE_WITH_INSTANCE_NAME` and `REPLACE_WITH_DB_NAME`.
2. Copy `.env.example` to `.env` and set `MYSQL_USER` / `MYSQL_PASSWORD`.

## Run locally

```bash
set -a; source .env; set +a
toolbox --config tools.yaml --port 5000
```

The MCP endpoint will be available at `http://localhost:5000/mcp`.
HTTP tool list: `curl http://localhost:5000/api/toolset/mysql-troubleshooting`

## Available toolset: `mysql-troubleshooting`

| Tool | Purpose |
|---|---|
| `show-global-status` | Key server counters (connections, InnoDB, tmp tables) |
| `show-processlist` | Active sessions, longest-running first |
| `show-replica-status` | Replication health and lag |
| `top-slow-queries` | Slowest digests from performance_schema |
| `full-table-scan-queries` | Queries doing full scans (sys schema) |
| `unused-indexes` | Indexes never used since restart |
| `redundant-indexes` | Drop candidates |
| `explain-query` | EXPLAIN FORMAT=JSON for a SELECT |
| `innodb-active-transactions` | Long-running InnoDB transactions |
| `innodb-lock-waits` | Blocked sessions and blockers |
| `largest-tables` | Top tables by total size |
| `table-fragmentation` | Candidates for `OPTIMIZE TABLE` |

## Next step

Wire this Toolbox into an ADK agent (see `../agent/`). Example:

```python
from toolbox_core import ToolboxSyncClient
from google.adk.agents import Agent

toolbox = ToolboxSyncClient("http://localhost:5000")
tools = toolbox.load_toolset("mysql-troubleshooting")

agent = Agent(
    name="mysql_dba_agent",
    model="gemini-2.5-pro",
    instruction="You are an on-call MySQL DBA. Diagnose issues using the tools.",
    tools=tools,
)
```
