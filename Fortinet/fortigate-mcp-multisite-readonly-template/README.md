# FortiGate Multi-Site Read-Only MCP Server (Template)

A minimal, security-conscious template for letting Claude (or any
MCP-compatible client) answer questions directly from **multiple**
FortiGate firewalls — system health, active VPN sessions, traffic logs,
firewall policy lookups — without ever being able to change anything on
any of them.

This is the multi-site sibling of
[`fortigate-mcp-readonly-template`](../fortigate-mcp-readonly-template) (a
single-site version). Use this one if you manage more than one FortiGate;
use the single-site template if you only ever have one and don't want the
extra `site` argument on every tool call.

---

## Design principles

1. **Read-only, in two independent layers.** Every tool in `server.py`
   only ever issues HTTP GET requests — there's no code path that can
   write, create, update, or delete anything, on any site. On top of that,
   the FortiGate-side account each site connects with should itself be
   locked to a read-only admin profile. If either layer is ever bypassed,
   the other still holds.
2. **A dedicated credential per site, not your personal login.** Each site
   gets its own REST API Admin account, not your own SSO/admin
   credentials, so each can be scoped, restricted, and revoked
   independently of the others and of you.
3. **Trusted Hosts, always, per site.** Lock each site's API admin account
   to the specific IP/subnet the script will run from when querying it.
   This means even a leaked token can't be used from anywhere else.
4. **No plaintext secrets, ever.** Every token lives in your OS's native
   credential store (via the `keyring` library) under its own derived
   name — not an environment variable, not a config file, not hardcoded.
5. **Configuration, not code, for adding sites.** The entire site registry
   is built from environment variables at startup. Adding, renaming, or
   removing a site never requires touching `server.py`.
6. **Respect existing network boundaries.** Most FortiGate deployments
   correctly restrict admin/API access to VPN or specific internal
   networks. This template doesn't try to work around that for any site —
   it assumes you'll run it from a machine that already has legitimate
   access to whichever site you're querying, the same way a human admin
   would.
7. **One site's problem stays that site's problem.** A missing token,
   revoked account, or network issue for one site only breaks calls to
   that site — every other configured site keeps working normally.

---

## Prerequisites

- One or more FortiGates running FortiOS 7.x (the REST API paths used here
  are stable across recent 7.x versions).
- Admin access to create a new administrator account on each one.
- Python 3.9+ and `pip` on the machine that will run this server.
- Claude Desktop (or another MCP-compatible client) — see Step 6.

---

## Step 1 — Create a read-only admin profile (on each FortiGate)

Repeat this on every FortiGate you plan to connect:

1. Log into the FortiGate's GUI, from a network/VPN that already has admin
   access.
2. Go to **System > Admin Profiles > Create New**.
3. Name it something like `readonly-api` (using the same name across all
   sites keeps things easy to audit later, but isn't required).
4. Set every category (Network, Policy & Objects, Security Profiles, Log &
   Report, VPN, etc.) to **Read Only**. Do not grant Read/Write on
   anything.
5. Save.

## Step 2 — Create a dedicated REST API admin account (on each FortiGate)

Repeat this on every FortiGate:

1. Go to **System > Administrators > Create New > REST API Admin**.
2. Give it an identifiable name, e.g. `readonly-api-mcp`.
3. Admin Profile: select the `readonly-api` profile from Step 1.
4. **Trusted Hosts** — restrict this to the specific IP or subnet the
   script will run from when reaching *this* site. Do not leave this open
   to "any." If you'll query this site from more than one location (e.g.
   another office's network, or that office's public WAN IP if traffic
   exits over NAT), you may need to add more than one entry — build this
   up by testing rather than guessing it all upfront.
5. Save. FortiOS will show you an **API token exactly once** per site —
   copy each one immediately into a password manager. If you lose one,
   you'll need to regenerate it (this just issues a fresh token for that
   account; it doesn't affect its other settings).

**Do not paste any of these tokens into a chat, ticket, or any file that
gets committed, synced, or shared.** Each one belongs only in your OS
credential store (Step 5) and, as a backup, your password manager.

## Step 3 — Install dependencies

```bash
pip install mcp requests keyring
```

(Only needs to be done once, regardless of how many sites you configure.)

## Step 4 — Configure your sites

Everything about which sites exist is driven by environment variables —
no code editing required. Pick a short, lowercase, no-spaces key for each
site (e.g. `hq`, `branch-1`, `dr-site`), then set:

```powershell
# Windows (PowerShell) -- persists across sessions
[System.Environment]::SetEnvironmentVariable("FORTIGATE_SITES", "hq,branch-1", "User")
[System.Environment]::SetEnvironmentVariable("FORTIGATE_HQ_BASE_URL", "https://fw-hq.example.com", "User")
[System.Environment]::SetEnvironmentVariable("FORTIGATE_BRANCH_1_BASE_URL", "https://fw-branch1.example.com", "User")
```

```bash
# macOS/Linux -- add to your shell profile to persist
export FORTIGATE_SITES="hq,branch-1"
export FORTIGATE_HQ_BASE_URL="https://fw-hq.example.com"
export FORTIGATE_BRANCH_1_BASE_URL="https://fw-branch1.example.com"
```

Notes:

- Each site key in `FORTIGATE_SITES` must have a matching
  `FORTIGATE_<KEY>_BASE_URL` (key uppercased, non-alphanumeric characters
  become underscores — e.g. `branch-1` → `FORTIGATE_BRANCH_1_BASE_URL`).
- (Optional) Override TLS verification for one site only if it uses a
  self-signed certificate you've confirmed is expected:
  `FORTIGATE_BRANCH_1_VERIFY_TLS=false`. Otherwise it inherits
  `FORTIGATE_VERIFY_TLS` (default `true` — leave it on unless you have a
  specific reason not to).
- Adding a third site later is additive: extend `FORTIGATE_SITES` and add
  its `_BASE_URL` variable. Nothing else changes.

## Step 5 — Store each site's token securely

Each site's token is stored under its own automatically-derived name --
`fortigate-<key>-readonly-mcp` -- so tokens can never accidentally
overwrite each other. Repeat this once per site, substituting the site's
key and its token:

**On Windows**, use this exact pattern — not `getpass.getpass()`:

```powershell
$token = Read-Host "Paste API token for site 'hq'"
$token | python -c "import keyring, sys; keyring.set_password('fortigate-hq-readonly-mcp', 'api_token', sys.stdin.readline().strip())"
```

> **Why not `getpass`?** On Windows, Python's `getpass.getpass()` reads
> keystrokes at a low level that doesn't understand Ctrl+V as "paste the
> clipboard" — it records the literal Ctrl+V control character instead of
> the actual clipboard contents. This silently stores a garbage
> 1-character "token" that causes every API call for that site to fail
> with a generic, confusing 401 — with nothing wrong on the FortiGate side
> at all. `Read-Host` goes through PowerShell's normal input handling,
> which pastes correctly, so pipe the value into Python instead of letting
> Python capture the paste itself.

**On macOS/Linux**, `getpass` doesn't have this issue, so the simpler form
works fine:

```bash
python3 -c "import keyring, getpass; keyring.set_password('fortigate-hq-readonly-mcp', 'api_token', getpass.getpass(\"Paste API token for site 'hq': \"))"
```

To confirm a token saved correctly, without ever printing it:

```bash
python -c "import keyring; print('stored OK' if keyring.get_password('fortigate-hq-readonly-mcp', 'api_token') else 'MISSING')"
```

On Windows, you can also sanity-check the *length* matches what you copied
(a quick way to catch silent corruption without printing the secret):

```powershell
python -c "import keyring; print('length:', len(keyring.get_password('fortigate-hq-readonly-mcp', 'api_token')))"
```

To rotate a token later, just re-run its `set_password` command — it
overwrites the old value for that site only.

## Step 6 — Add this server to your MCP client

For Claude Desktop, check Settings for a "Developer" or "MCP servers"
section — it usually has a button to open the config file directly rather
than needing to find it manually. Add an entry like:

```json
{
  "mcpServers": {
    "fortigate-multisite": {
      "command": "python",
      "args": ["/full/path/to/server.py"]
    }
  }
}
```

Some Claude Desktop builds store this as a top-level key inside a larger,
shared settings file rather than a dedicated one — if so, add `mcpServers`
alongside whatever else is already in that file, don't replace it.

Environment variables set via `SetEnvironmentVariable("...", "User")` (or
your shell profile on macOS/Linux) are picked up automatically since
they're set at the user/session level, not just in one terminal — but if
you set them in a terminal only, launch Claude Desktop from that same
terminal, or restart your machine so the "User"-scoped variables take
effect everywhere.

Save, then fully quit and reopen Claude Desktop (closing the window isn't
enough — the server is a separate process it needs to relaunch).

## Step 7 — Test it

Make sure you're on a network that can actually reach each FortiGate's
admin interface, then ask your MCP client things like:

- "What sites is the FortiGate server configured for?" (uses `list_sites`)
- "What's hq's system status?"
- "Are there any active SSL-VPN sessions on branch-1 right now?"
- "Show me denied traffic on hq in the last few log entries."
- "What does firewall policy 5 on branch-1 do?"

If one site fails, the others should be unaffected — that's by design.

---

## Troubleshooting

**Getting a 400 with an empty response body?** This often means the
request is being rejected before it reaches FortiOS's normal API handling
— check whether you're sending the token via the `Authorization: Bearer`
header vs. as an `?access_token=` query parameter; some deployments behave
differently depending on which method is used. Try both.

**Getting a 401 (with or without a body) for one specific site?** First
confirm that site's account setup is actually correct by testing the
*identical* endpoint URL in a browser where you're already logged into
that FortiGate's GUI via session/SSO — if that works but the token-based
call doesn't, the account and network path are fine for that site, and the
problem is specifically with its token or how it's being sent. Re-check
for accidental corruption (see the `getpass`/Ctrl+V note in Step 5) before
assuming the account is misconfigured.

**Getting a 403 for one site after fixing the token?** This usually means
Trusted Hosts, not the credential — the request is authenticating fine but
being rejected based on source IP. Confirm what IP you're actually
appearing as (your local subnet if querying from that site's own network,
or your public WAN IP if reaching it from elsewhere over NAT), and check
it against that site's Trusted Hosts entries.

**Nothing works at all for a given site (timeouts, connection refused)?**
You're very likely not on a network that has admin/API access to that
specific FortiGate. Check VPN connection and confirm with whoever manages
that firewall which networks/VLANs are permitted — this can differ
per site.

**"Unknown site" errors?** Call `list_sites()` to see exactly which keys
this server currently recognizes, and double check `FORTIGATE_SITES` and
the matching `_BASE_URL` variable are both set and spelled consistently.

---

## What this deliberately does NOT do

- No tool here can create, edit, or delete a firewall policy, admin
  account, or any other config object, on any site — every call is a GET
  request.
- Each site's API admin account should be locked to read-only permissions
  and specific trusted hosts, independently of the others, so even if one
  token were ever misused, it can't modify anything, reach another site,
  or be used from an unexpected location.
- This does not expose any FortiGate to the public internet in any way it
  wasn't already — it relies entirely on network access you already have,
  per site.

## Scaling beyond one person/one device

This template is intentionally simple: one local process, one person,
several FortiGates. Turning it into something a whole team can use safely
is a bigger step, roughly in this order:

1. **Host it centrally** — an always-on service inside the same network
   boundary the FortiGates already restrict access to, rather than a
   single laptop.
2. **Add real per-user authentication** — a shared, centrally-hosted
   server needs to know who's asking, not just trust whoever can reach it.
   Running it as a "remote" MCP server with OAuth (via whatever identity
   provider your organization already uses — Entra ID, Okta, etc.) means
   each person signs in with their existing credentials, and every request
   is attributable to a real person.
3. **Move secrets into a real secrets manager** (e.g. Azure Key Vault, AWS
   Secrets Manager, HashiCorp Vault) instead of one machine's local
   credential store, since a shared server may need to hold credentials
   for many sites and many users.
4. **Add audit logging** — once more than one person can query production
   firewall data through this, "who asked what, about which site, when"
   stops being optional.
5. **Get sign-off from whoever owns each firewall estate** before treating
   this as team infrastructure rather than one person's tool — especially
   since a shared deployment now spans multiple sites' trust boundaries at
   once.
