# MySQL DBA Agent (ADK)

An [Agent Development Kit](https://google.github.io/adk-docs/) agent that uses the
read-only MySQL tools exposed by the local MCP Toolbox server (see `../mcp-toolbox/`).

## Setup

```bash
cd GCP/mysql-agent/agent
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Authenticate to Vertex AI (used to call Gemini):

```bash
gcloud auth application-default login
gcloud config set project dre-sandbox-471618
```

Set env vars (or put them in `.env`):

```bash
export GOOGLE_GENAI_USE_VERTEXAI=true
export GOOGLE_CLOUD_PROJECT=dre-sandbox-471618
export GOOGLE_CLOUD_LOCATION=us-central1
export TOOLBOX_URL=http://localhost:5000
```

## Run

In one terminal, start the Toolbox:

```bash
cd ../mcp-toolbox
set -a; source .env; set +a
toolbox --config tools.yaml --port 5000
```

In another, launch the agent UI:

```bash
cd GCP/mysql-agent
adk web
```

Then open the printed URL and select `mysql_dba_agent`.

You can also run a one-shot CLI session:

```bash
adk run mysql_dba_agent
```

## Files

- [mysql_dba_agent/agent.py](mysql_dba_agent/agent.py) — agent definition + tool wiring
- [mysql_dba_agent/prompt.py](mysql_dba_agent/prompt.py) — DBA troubleshooting playbook prompt
- [requirements.txt](requirements.txt) — pinned deps
