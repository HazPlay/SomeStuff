# FortiGate Read-Only MCP Server (Template)

A minimal, security-conscious template for letting Claude (or any
MCP-compatible client) answer questions directly from a FortiGate firewall —
system health, active VPN sessions, traffic logs, firewall policy lookups —
without ever being able to change anything on it.

This started as a proof-of-concept for a single site and has been
generalized here so anyone can adapt it to their own environment.

---

## Design principles

1. **Read-only, in two independent layers.** Every tool in `server.py` only
   ever issues HTTP GET requests — there's no code path that can write,
   create, update, or delete anything. On top of that, the FortiGate-side
   account this connects with should itself be locked to a read-only admin
   profile. If either layer is ever bypassed, the other still holds.
2. **A dedicated credential, not your personal login.** Use a separate REST
   API Admin account, not your own SSO/admin credentials, so it can be
   scoped, restricted, and revoked independently.
3. **Trusted Hosts, always.** Lock the API admin account to the specific
   IP/subnet the script will run from. This means even a leaked token can't
   be used from anywhere else.
4. **No plaintext secrets.** The token lives in your OS's native credential
   store (via the `keyring` library), not an environment variable, not a
   config file, not hardcoded in the script.
5. **Respect existing network boundaries.** Most FortiGate deployments
   correctly restrict admin/API access to VPN or specific internal networks.
   This template doesn't try to work around that — it assumes you'll run it
   from a machine that already has legitimate access, the same way a human
   admin would.

---

## Prerequisites

- A FortiGate running FortiOS 7.x (the REST API paths used here are stable
  across recent 7.x versions).
- Admin access to create a new administrator account on it.
- Python 3.9+ and `pip` on the machine that will run this server.
- Claude Desktop (or another MCP-compatible client) — see Step 5.

---

## Step 1 — Create a read-only admin profile

1. Log into your FortiGate's GUI, from a network/VPN that already has admin
   access.
2. Go to **System > Admin Profiles > Create New**.
3. Name it something like `readonly-api`.
4. Set every category (Network, Policy & Objects, Security Profiles, Log &
   Report, VPN, etc.) to **Read Only**. Do not grant Read/Write on anything.
5. Save.

## Step 2 — Create a dedicated REST API admin account

1. Go to **System > Administrators > Create New > REST API Admin**.
2. Give it an identifiable name, e.g. `readonly-api-mcp`.
3. Admin Profile: select the `readonly-api` profile from Step 1.
4. **Trusted Hosts** — restrict this to the specific IP or subnet the
   script will run from. Do not leave this open to "any."
5. Save. FortiOS will show you an **API token exactly once** — copy it
   immediately into a password manager. If you lose it, you'll need to
   regenerate a new one (this just creates a fresh token; it doesn't affect
   the account's other settings).

**Do not paste this token into a chat, ticket, or any file that gets
committed, synced, or shared.** It belongs only in your OS credential store
(next step) and, as a backup, your password manager.

## Step 3 — Install dependencies

```bash
pip install mcp requests keyring
```

## Step 4 — Store the token securely

This stores the token in your OS's native credential store (Windows
Credential Manager / macOS Keychain / Linux Secret Service via `keyring`),
encrypted at rest, instead of as plain text.

**On Windows**, use this exact pattern — not `getpass.getpass()`:

```powershell
$token = Read-Host "Paste FortiGate API token"
$token | python -c "import keyring, sys; keyring.set_password('fortigate-readonly-mcp', 'api_token', sys.stdin.readline().strip())"
```

> **Why not `getpass`?** On Windows, Python's `getpass.getpass()` reads
> keystrokes at a low level that doesn't understand Ctrl+V as "paste the
> clipboard" — it records the literal Ctrl+V control character instead of
> the actual clipboard contents. This silently stores a garbage 1-character
> "token" that causes every API call to fail with a generic, confusing 401
> — with nothing wrong on the FortiGate side at all. `Read-Host` goes through
> PowerShell's normal input handling, which pastes correctly, so pipe the
> value into Python instead of letting Python capture the paste itself.

**On macOS/Linux**, `getpass` doesn't have this issue, so the simpler form
works fine:

```bash
python3 -c "import keyring, getpass; keyring.set_password('fortigate-readonly-mcp', 'api_token', getpass.getpass('Paste FortiGate API token: '))"
```

To confirm it saved correctly, without ever printing the token itself:

```bash
python -c "import keyring; print('stored OK' if keyring.get_password('fortigate-readonly-mcp', 'api_token') else 'MISSING')"
```

If you're on Windows and want to double-check the *length* matches what you
copied (a quick way to catch silent corruption without printing the
secret):

```powershell
python -c "import keyring; print('length:', len(keyring.get_password('fortigate-readonly-mcp', 'api_token')))"
```

To rotate the token later, just re-run the `set_password` command — it
overwrites the old value.

## Step 5 — Set the FortiGate's address

```powershell
[System.Environment]::SetEnvironmentVariable("FORTIGATE_BASE_URL", "https://your-fortigate-hostname-or-ip", "User")
```

(Optional) If your FortiGate uses a self-signed certificate and you've
confirmed that's expected in your environment, you can disable TLS
verification the same way — but leave it on by default:

```powershell
[System.Environment]::SetEnvironmentVariable("FORTIGATE_VERIFY_TLS", "false", "User")
```

## Step 6 — Add this server to your MCP client

For the standard Claude Desktop config, edit (or create)
`claude_desktop_config.json` — location varies by OS and Claude Desktop
version; check Claude Desktop's own Settings for a "Developer" or "MCP
servers" section, which usually has a button to open this file directly
rather than needing to find it manually. Add an entry like:

```json
{
  "mcpServers": {
    "fortigate-readonly": {
      "command": "python",
      "args": ["/full/path/to/server.py"]
    }
  }
}
```

Some Claude Desktop builds store this as a top-level key inside a larger,
shared settings file rather than a dedicated one — if so, add `mcpServers`
alongside whatever else is already in that file, don't replace it.

Save, then fully quit and reopen Claude Desktop (closing the window isn't
enough — the server is a separate process it needs to relaunch).

## Step 7 — Test it

Make sure you're on a network that can actually reach the FortiGate's admin
interface, then ask your MCP client things like:

- "What's the FortiGate's system status?"
- "Are there any active SSL-VPN sessions right now?"
- "Show me denied traffic in the last few log entries."
- "What does firewall policy 5 do?"

---

## Troubleshooting

**Getting a 400 with an empty response body?** This often means the request
is being rejected before it reaches FortiOS's normal API handling — check
whether you're sending the token via the `Authorization: Bearer` header vs.
as an `?access_token=` query parameter; some deployments behave differently
depending on which method is used. Try both.

**Getting a 401 (with or without a body)?** First confirm the account setup
is actually correct by testing the *identical* endpoint URL in a browser
where you're already logged into the FortiGate GUI via session/SSO — if
that works but the token-based call doesn't, the account and network path
are fine, and the problem is specifically with the token or how it's being
sent. Re-check for accidental corruption (see the `getpass`/Ctrl+V note in
Step 4) before assuming the account is misconfigured.

**Nothing works at all (timeouts, connection refused)?** You're very likely
not on a network that has admin/API access to this FortiGate. Check VPN
connection and confirm with whoever manages the firewall which
networks/VLANs are permitted.

---

## What this deliberately does NOT do

- No tool here can create, edit, or delete a firewall policy, admin account,
  or any other config object — every call is a GET request.
- The API admin account itself should be locked to read-only permissions
  and a specific trusted host, so even if the token were ever misused, it
  can't modify anything or be used from an unexpected location.
- This does not expose the FortiGate to the public internet in any way it
  wasn't already — it relies entirely on network access you already have.

## Scaling beyond one person/one device

This template is intentionally simple: one local process, one person, one
FortiGate. Turning it into something a whole team can use safely is a
bigger step, roughly in this order:

1. **Host it centrally** — an always-on service inside the same network
   boundary the FortiGate already restricts access to, rather than a
   single laptop.
2. **Add real per-user authentication** — a shared, centrally-hosted server
   needs to know who's asking, not just trust whoever can reach it. Running
   it as a "remote" MCP server with OAuth (via whatever identity provider
   your organization already uses — Entra ID, Okta, etc.) means each person
   signs in with their existing credentials, and every request is
   attributable to a real person.
3. **Move secrets into a real secrets manager** (e.g. Azure Key Vault, AWS
   Secrets Manager, HashiCorp Vault) instead of one machine's local
   credential store, since a shared server may need to hold credentials for
   multiple devices.
4. **Extend to additional devices** — structure the target FortiGate's
   address as configuration, not a hardcoded value (already done in this
   template), so adding more devices is additive rather than a rewrite.
5. **Add audit logging** — once more than one person can query production
   firewall data through this, "who asked what, when" stops being optional.
6. **Get sign-off from whoever owns the firewall estate** before treating
   this as team infrastructure rather than one person's tool.
