# GroupDesk

A local M365 group housekeeping dashboard with live write actions — runs entirely on your machine, authenticates via Entra ID, and never exposes a client secret.

Built by [HazPlay](https://github.com/HazPlay) · MIT Licence

---

## What it does

GroupDesk starts a local web server on `localhost` and opens a browser dashboard where you can:

- **Browse all your M365 groups** — Microsoft 365, Security, Distribution, and Teams-connected groups
- **Spot housekeeping issues** — inactive members/owners, empty groups, groups with no owner, stale groups, nested groups, on-prem synced groups, and guest members
- **Add and remove members and owners** — write actions hit the real Entra ID, every action requires explicit confirmation
- **View users and their group memberships** — see which users belong to which groups and flag inactive accounts
- **Export to CSV** — download a snapshot of the current filtered view
- **Review an action log** — every add/remove is timestamped and attributed to the signed-in user

---

## How it works

```
Browser  ←→  PowerShell HttpListener (localhost)  ←→  Microsoft Graph API
```

- **No backend server** — PowerShell's built-in `HttpListener` is the web server
- **No client secret** — authentication uses PKCE OAuth 2.0 (Proof Key for Code Exchange)
- **Token in RAM only** — the access token is never written to disk and is cleared on exit or logout
- **All Graph calls are server-side** — the browser never touches the API directly

---

## Prerequisites

- **PowerShell 7+** — download from [aka.ms/powershell](https://aka.ms/powershell)
- **An Entra ID App Registration** — one-time setup, see below
- **Admin consent** for the required Graph permissions

---

## App Registration setup (one-time)

1. Go to **Entra Admin Center** → **App registrations** → **New registration**
2. Name it anything (e.g. `GroupDesk`)
3. Supported account types: **Accounts in this organisational directory only**
4. Platform: **Mobile and desktop applications**
   - Redirect URI: `http://localhost:8743/callback`
   - If you use a custom port, replace `8743` with your chosen port
5. Under **API permissions** → **Add a permission** → **Microsoft Graph** → **Delegated**:

   | Permission | Purpose |
   |---|---|
   | `Group.Read.All` | Read group details |
   | `GroupMember.ReadWrite.All` | Add/remove members |
   | `Group.ReadWrite.All` | Add/remove owners |
   | `User.Read.All` | Read user details |
   | `Reports.Read.All` | Activity-based stale detection *(optional)* |

6. Click **Grant admin consent** for your organisation
7. Go to **Enterprise Applications** → your app → **Properties** → set **User assignment required** to `Yes`
8. Go to **Users and groups** → add the users or security groups who should have access

---

## Running GroupDesk

```powershell
pwsh .\groupdesk.ps1 -TenantId "YOUR-TENANT-ID" -ClientId "YOUR-CLIENT-ID"
```

The browser will open automatically. Sign in with your Entra account.

### Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-TenantId` | Yes | — | Your Entra tenant ID (GUID) |
| `-ClientId` | Yes | — | App Registration client ID (GUID) |
| `-Port` | No | `8743` | Local port for the web server |
| `-StaleDays` | No | `90` | Days of inactivity before flagging M365 groups as stale |
| `-NoBrowser` | No | `false` | Skip auto-opening the browser |

### Example with custom port

```powershell
pwsh .\groupdesk.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -Port 9000 -StaleDays 60
```

Remember to update the Redirect URI in your App Registration to match the port.

---

## Issue flags

| Flag | Meaning |
|---|---|
| ⚠ Inactive (N) | N members have `accountEnabled = false` |
| ⚠ Inactive Owner | One or more owners have `accountEnabled = false` |
| Empty | No active members |
| No Owner | M365/Security group has no assigned owner |
| Stale | No activity in the configured number of days |
| Nested | Contains nested groups as members |
| On-Prem | Synced from on-premises AD |
| Guests (N) | Contains N guest users |

> **Stale detection** uses Microsoft 365 activity reports if `Reports.Read.All` is granted. Without it, GroupDesk falls back to `renewedDateTime` as a proxy.

---

## Security design

- **Binds to localhost only** — not accessible from the network
- **No client secret** — PKCE flow only; if the app registration is compromised, there is no secret to leak
- **Token in RAM** — cleared on `Ctrl+C` or logout; never written to disk
- **Confirmation required** — every add or remove action shows a confirmation dialog before executing
- **CSRF protection** — `Origin` header is checked on all write requests
- **Input validation** — all group and user IDs extracted from URLs are validated as GUIDs before use
- **Security headers** — every response includes `X-Content-Type-Options`, `X-Frame-Options`, `CSP`, `Referrer-Policy`, and `Cache-Control: no-store`

---

## Permissions note

GroupDesk uses **delegated permissions** — it acts as the signed-in user, not as the app itself. Every write action (add/remove member/owner) is performed under the identity of the person who signed in, and logged with their name. This means the audit trail in Entra reflects the real user, not a service account.

---

## Stopping GroupDesk

Press `Ctrl+C` in the terminal. The token and all cached data are cleared from memory.

---

## Licence

MIT — see [LICENCE](LICENCE) for full text.

Copyright (c) 2026 HazPlay
