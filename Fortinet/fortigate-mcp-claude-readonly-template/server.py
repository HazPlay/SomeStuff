"""
FortiGate read-only MCP server (template)
==========================================

A small, generic template for exposing READ-ONLY tools against a FortiGate's
REST API, for use with Claude Desktop (or any MCP-compatible client) as a
local MCP server. Adapt the placeholders below for your own environment.

SECURITY NOTES (read before running):
- This script only ever issues HTTP GET requests. There is no code path here
  that can write, create, update, or delete any FortiGate configuration or
  object. Keep it that way -- do not add write calls to this file.
- It expects a DEDICATED REST API Admin account on your FortiGate with a
  READ-ONLY admin profile, and Trusted Hosts locked to the machine(s) this
  script will run on. See README.md for how to create that account -- you
  need to create it yourself in the FortiGate GUI; it's a security-setting
  change that shouldn't be automated or handed off.
- The API token is stored via the `keyring` library, which uses your OS's
  native credential store (Windows Credential Manager, macOS Keychain, or
  the Linux Secret Service) -- encrypted at rest, never written to disk in
  plain text by this script, and never hardcoded here.
- This server must run on a machine that already has network access to the
  target FortiGate (e.g. connected to the right internal network or VPN) --
  it will not work from a machine that isn't on that network, by design.
  Most FortiGate deployments correctly restrict admin/API access this way;
  this script doesn't try to work around that, it relies on it.
"""

import os
from typing import Optional

import keyring
import requests
from mcp.server.fastmcp import FastMCP

# --- Configuration -----------------------------------------------------
# Set these for your environment. BASE_URL should be the FortiGate's admin
# hostname or IP, e.g. "https://fw.example.com" or "https://10.0.0.1".
BASE_URL = os.environ.get("FORTIGATE_BASE_URL")
VERIFY_TLS = os.environ.get("FORTIGATE_VERIFY_TLS", "true").lower() != "false"

# Used as the lookup key in your OS credential store -- change this if you
# run multiple instances of this template against different FortiGates.
CREDENTIAL_SERVICE = "fortigate-readonly-mcp"
CREDENTIAL_USERNAME = "api_token"

if not BASE_URL:
    raise RuntimeError(
        "FORTIGATE_BASE_URL environment variable is not set.\n"
        "Set it to your FortiGate's admin URL, e.g. "
        "https://fw.example.com, before launching this server."
    )

API_TOKEN = keyring.get_password(CREDENTIAL_SERVICE, CREDENTIAL_USERNAME)

if not API_TOKEN:
    raise RuntimeError(
        "No API token found in your OS credential store for "
        f"service='{CREDENTIAL_SERVICE}'.\n"
        "See README.md for how to generate a read-only API token on your "
        "FortiGate and store it securely."
    )

mcp = FastMCP("fortigate-readonly")


def _get(path: str, params: Optional[dict] = None) -> dict:
    """Internal helper. GET only -- never used for writes. Do not reuse this
    for POST/PUT/DELETE."""
    url = f"{BASE_URL}{path}"
    headers = {"Authorization": f"Bearer {API_TOKEN}"}
    resp = requests.get(
        url, headers=headers, params=params or {}, verify=VERIFY_TLS, timeout=15
    )
    if not resp.ok:
        # Surface the FortiGate's own error body instead of swallowing it --
        # a generic "400/401" alone usually isn't enough to diagnose what's
        # wrong. See README.md's troubleshooting section for how to read
        # these.
        raise RuntimeError(
            f"FortiGate API error {resp.status_code} calling {url}\n"
            f"Response body: {resp.text[:2000]}"
        )
    return resp.json()


@mcp.tool()
def get_system_status() -> dict:
    """Get FortiGate system status: hostname, model, firmware version,
    serial number, and HA status."""
    return _get("/api/v2/monitor/system/status")


@mcp.tool()
def get_resource_usage() -> dict:
    """Get current CPU and memory usage on the FortiGate."""
    return _get(
        "/api/v2/monitor/system/resource/usage",
        {"resource": ["cpu", "mem"]},
    )


@mcp.tool()
def get_active_vpn_sessions() -> dict:
    """List currently active SSL-VPN sessions on the FortiGate -- connected
    users, their source IP, and connection duration."""
    return _get("/api/v2/monitor/vpn/ssl")


@mcp.tool()
def search_traffic_logs(filter: str = "", rows: int = 50) -> dict:
    """
    Search recent forward traffic logs on the FortiGate.

    Args:
        filter: FortiOS log filter expression, e.g. "action==deny" or
                "srcip==10.0.0.5". Leave empty to return the most recent
                traffic log entries unfiltered.
        rows: Max number of log rows to return (default 50, max 999).
    """
    params: dict = {"rows": min(rows, 999)}
    if filter:
        params["filter"] = filter
    return _get("/api/v2/log/disk/traffic/forward/system", params)


@mcp.tool()
def list_firewall_policies() -> dict:
    """List all firewall policies configured on the FortiGate (read-only --
    names, source/destination, action, but does not change anything)."""
    return _get("/api/v2/cmdb/firewall/policy")


@mcp.tool()
def get_firewall_policy(policy_id: int) -> dict:
    """Get the full detail of a single firewall policy by its numeric ID
    (read-only)."""
    return _get(f"/api/v2/cmdb/firewall/policy/{policy_id}")


if __name__ == "__main__":
    mcp.run()
