"""
FortiGate multi-site read-only MCP server (template)
=====================================================

A generic template for exposing READ-ONLY tools against MULTIPLE FortiGate
sites' REST APIs, for use with Claude Desktop (or any MCP-compatible
client) as a local MCP server. Every tool takes a `site` argument, so the
client always says explicitly which FortiGate it means -- no ambiguity
about which firewall is being queried.

This is the multi-site sibling of the single-site
`fortigate-mcp-readonly-template`. Use this one if you manage more than one
FortiGate; use the single-site template if you only ever have one and don't
want the extra `site` argument on every call.

Adding, removing, or renaming a site is pure configuration -- no code
changes needed. See README.md Step 4.

SECURITY NOTES (read before running):
- This script only ever issues HTTP GET requests. There is no code path
  here that can write, create, update, or delete any FortiGate
  configuration or object, on any site. Keep it that way -- do not add
  write calls to this file.
- Each site needs its OWN dedicated REST API Admin account with a
  READ-ONLY admin profile, and Trusted Hosts locked to wherever this
  script will legitimately run from for that site. See README.md -- you
  need to create these accounts yourself in each FortiGate's GUI; that's a
  security-setting change that shouldn't be automated or handed off.
- Each site's API token is stored under its own derived `keyring` service
  name (see _load_sites() below), so tokens can never accidentally
  overwrite each other the way a single shared name could.
- A missing or bad token/config for one site only breaks calls to that
  site -- other configured sites keep working normally.
- This server must run on a machine that already has legitimate network
  access to whichever site is being queried (VPN or the relevant internal
  network). It will not work otherwise, by design. Most FortiGate
  deployments correctly restrict admin/API access this way; this script
  doesn't try to work around that, it relies on it.
"""

import os
import re
from typing import Optional

import keyring
import requests
from mcp.server.fastmcp import FastMCP

VERIFY_TLS_DEFAULT = os.environ.get("FORTIGATE_VERIFY_TLS", "true").lower() != "false"


def _env_key(site: str) -> str:
    """Turn a site key like "branch-1" into a safe env var fragment like
    "BRANCH_1"."""
    return re.sub(r"[^A-Za-z0-9]", "_", site).upper()


def _load_sites() -> dict:
    """Build the site registry entirely from environment variables.

    Set FORTIGATE_SITES to a comma-separated list of short site keys, e.g.:
        FORTIGATE_SITES=hq,branch-1,dr-site

    Then for each key, set its base URL:
        FORTIGATE_HQ_BASE_URL=https://fw-hq.example.com
        FORTIGATE_BRANCH_1_BASE_URL=https://fw-branch1.example.com
        FORTIGATE_DR_SITE_BASE_URL=https://fw-dr.example.com

    Optionally override TLS verification per site (defaults to
    FORTIGATE_VERIFY_TLS, which itself defaults to true):
        FORTIGATE_BRANCH_1_VERIFY_TLS=false

    Each site's credential store lookup key is derived automatically as
    "fortigate-<key>-readonly-mcp" -- no need to configure this separately,
    and no risk of two sites accidentally sharing a credential name.
    """
    raw = os.environ.get("FORTIGATE_SITES", "")
    keys = [s.strip().lower() for s in raw.split(",") if s.strip()]
    sites: dict = {}
    for key in keys:
        env_key = _env_key(key)
        base_url = os.environ.get(f"FORTIGATE_{env_key}_BASE_URL")
        if not base_url:
            raise RuntimeError(
                f"Site '{key}' is listed in FORTIGATE_SITES but "
                f"FORTIGATE_{env_key}_BASE_URL is not set. See README.md "
                "Step 4."
            )
        verify_env = os.environ.get(f"FORTIGATE_{env_key}_VERIFY_TLS")
        verify_tls = (
            verify_env.lower() != "false"
            if verify_env is not None
            else VERIFY_TLS_DEFAULT
        )
        sites[key] = {
            "base_url": base_url,
            "credential_service": f"fortigate-{key}-readonly-mcp",
            "verify_tls": verify_tls,
        }
    return sites


SITES = _load_sites()

if not SITES:
    raise RuntimeError(
        "No sites configured. Set FORTIGATE_SITES to a comma-separated "
        "list of site keys (e.g. \"hq,branch-1\") and set "
        "FORTIGATE_<KEY>_BASE_URL for each one. See README.md Step 4."
    )

mcp = FastMCP("fortigate-multisite-readonly")


def _site_config(site: str) -> dict:
    key = (site or "").strip().lower()
    if key not in SITES:
        valid = ", ".join(sorted(SITES))
        raise ValueError(f"Unknown site '{site}'. Configured sites: {valid}")
    return SITES[key]


def _get(site: str, path: str, params: Optional[dict] = None) -> dict:
    """Internal helper. GET only -- never used for writes. Do not reuse this
    for POST/PUT/DELETE."""
    cfg = _site_config(site)
    token = keyring.get_password(cfg["credential_service"], "api_token")
    if not token:
        raise RuntimeError(
            f"No API token found for site '{site}' "
            f"(credential service '{cfg['credential_service']}'). Store "
            "one for this site before querying it -- see README.md Step 5."
        )

    url = f"{cfg['base_url']}{path}"
    headers = {"Authorization": f"Bearer {token}"}
    resp = requests.get(
        url, headers=headers, params=params or {}, verify=cfg["verify_tls"],
        timeout=15,
    )
    if not resp.ok:
        # Surface the FortiGate's own error body instead of swallowing it --
        # a generic status code alone usually isn't enough to diagnose what
        # went wrong. See README.md's troubleshooting section.
        raise RuntimeError(
            f"FortiGate API error {resp.status_code} calling {url} "
            f"(site={site})\nResponse body: {resp.text[:2000]}"
        )
    return resp.json()


@mcp.tool()
def list_sites() -> dict:
    """List the FortiGate sites this server is currently configured for.
    Call this first if you're not sure what to pass as `site` in the other
    tools."""
    return {"sites": sorted(SITES)}


@mcp.tool()
def get_system_status(site: str) -> dict:
    """Get system status for a FortiGate site: hostname, model, firmware
    version, serial number, and HA status.

    Args:
        site: Which configured FortiGate to query. Call list_sites() first
              if unsure which keys are available.
    """
    return _get(site, "/api/v2/monitor/system/status")


@mcp.tool()
def get_resource_usage(site: str) -> dict:
    """Get current CPU and memory usage for a FortiGate site.

    Args:
        site: Which configured FortiGate to query. Call list_sites() first
              if unsure which keys are available.
    """
    # FortiOS's resource/usage endpoint requires "resource" as a single
    # value per call (not a list) plus a required "scope" parameter -- it
    # returns an unhelpful generic 400 if either is wrong, so this makes
    # two separate calls and combines them.
    cpu = _get(
        site, "/api/v2/monitor/system/resource/usage",
        {"resource": "cpu", "scope": "vdom"},
    )
    mem = _get(
        site, "/api/v2/monitor/system/resource/usage",
        {"resource": "mem", "scope": "vdom"},
    )
    return {
        "cpu": cpu.get("results", {}).get("cpu"),
        "mem": mem.get("results", {}).get("mem"),
    }


@mcp.tool()
def get_active_vpn_sessions(site: str) -> dict:
    """List currently active SSL-VPN sessions for a FortiGate site --
    connected users, their source IP, and connection duration.

    Args:
        site: Which configured FortiGate to query. Call list_sites() first
              if unsure which keys are available.
    """
    return _get(site, "/api/v2/monitor/vpn/ssl")


@mcp.tool()
def search_traffic_logs(site: str, filter: str = "", rows: int = 50) -> dict:
    """
    Search recent forward traffic logs for a FortiGate site.

    Args:
        site: Which configured FortiGate to query. Call list_sites() first
              if unsure which keys are available.
        filter: FortiOS log filter expression, e.g. "action==deny" or
                "srcip==10.0.0.5". Leave empty to return the most recent
                traffic log entries unfiltered.
        rows: Max number of log rows to return (default 50, max 999).
    """
    params: dict = {"rows": min(rows, 999)}
    if filter:
        params["filter"] = filter
    return _get(site, "/api/v2/log/disk/traffic/forward/system", params)


def _summarize_policy(p: dict) -> dict:
    """Trim a raw FortiOS policy object down to the fields actually useful
    for answering questions, dropping the many verbose sub-objects (UTM
    profile bindings, per-field metadata, etc.) that can otherwise make a
    site with many policies return a result too large for a chat client to
    display."""

    def _names(field):
        val = p.get(field)
        if isinstance(val, list):
            return [
                item.get("name", item) if isinstance(item, dict) else item
                for item in val
            ]
        return val

    return {
        "policyid": p.get("policyid"),
        "name": p.get("name"),
        "status": p.get("status"),
        "srcintf": _names("srcintf"),
        "dstintf": _names("dstintf"),
        "srcaddr": _names("srcaddr"),
        "dstaddr": _names("dstaddr"),
        "service": _names("service"),
        "action": p.get("action"),
        "schedule": p.get("schedule"),
        "logtraffic": p.get("logtraffic"),
        "comments": p.get("comments"),
    }


@mcp.tool()
def list_firewall_policies(site: str) -> dict:
    """List firewall policies configured on a FortiGate site (read-only).
    Returns a trimmed summary per policy (ID, name, status, source/dest
    interfaces and addresses, service, action, schedule, comments) rather
    than the full raw FortiOS object, since sites with many policies can
    otherwise produce an oversized result. Use get_firewall_policy for the
    full detail of one specific policy.

    Args:
        site: Which configured FortiGate to query. Call list_sites() first
              if unsure which keys are available.
    """
    raw = _get(site, "/api/v2/cmdb/firewall/policy")
    results = raw.get("results", [])
    return {
        "count": len(results),
        "policies": [_summarize_policy(p) for p in results],
    }


@mcp.tool()
def get_firewall_policy(site: str, policy_id: int) -> dict:
    """Get the full detail of a single firewall policy by its numeric ID,
    for a given site (read-only).

    Args:
        site: Which configured FortiGate to query. Call list_sites() first
              if unsure which keys are available.
        policy_id: The numeric policy ID.
    """
    return _get(site, f"/api/v2/cmdb/firewall/policy/{policy_id}")


if __name__ == "__main__":
    mcp.run()
