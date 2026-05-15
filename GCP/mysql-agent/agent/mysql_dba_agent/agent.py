"""MySQL DBA troubleshooting agent.

Loads read-only MySQL diagnostic tools from an MCP Toolbox server (local or
Cloud Run) and exposes them to a Gemini-powered ADK agent.
"""

from __future__ import annotations

import os

import google.auth
import google.auth.transport.requests
from dotenv import load_dotenv
from google.adk.agents import Agent
from google.oauth2 import id_token
from toolbox_core import ToolboxSyncClient

from .prompt import SYSTEM_PROMPT

load_dotenv()

TOOLBOX_URL = os.getenv("TOOLBOX_URL", "http://localhost:5000")
MODEL = os.getenv("MYSQL_AGENT_MODEL", "gemini-2.5-pro")
TOOLSET = os.getenv("MYSQL_AGENT_TOOLSET", "mysql-troubleshooting")


def _id_token_provider() -> str:
    """Mint a Google ID token whose audience is the Toolbox URL.

    Used when TOOLBOX_URL points at a private Cloud Run service.
    """
    auth_req = google.auth.transport.requests.Request()
    return id_token.fetch_id_token(auth_req, TOOLBOX_URL)


_client_kwargs = {}
if TOOLBOX_URL.startswith("https://") and "run.app" in TOOLBOX_URL:
    _client_kwargs["client_headers"] = {
        "Authorization": lambda: f"Bearer {_id_token_provider()}",
    }

_toolbox = ToolboxSyncClient(TOOLBOX_URL, **_client_kwargs)
_tools = _toolbox.load_toolset(TOOLSET)

root_agent = Agent(
    name="mysql_dba_agent",
    model=MODEL,
    description="On-call MySQL DBA that triages Cloud SQL issues using read-only tools.",
    instruction=SYSTEM_PROMPT,
    tools=_tools,
)
