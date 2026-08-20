# M365 Onboarding Runbook

An Azure Automation runbook that creates a new hire's account in Entra ID, sets their manager, and optionally assigns a license. Companion to the M365 Offboarding Runbook (`Offboarding_Basic.ps1`) - runs unattended via the same Automation Account's **system-assigned managed identity**, no passwords, client secrets, or certificates stored anywhere.

Scoped deliberately: account creation + manager + license, plus an optional IT-facing summary email. No Temporary Access Pass (TAP), no welcome/day-one email to the new hire, no Enterprise Application assignment, no manual group-add, no Exchange-specific mailbox setup, no Exchange Online connection at all - see [Explicitly out of scope](#explicitly-out-of-scope).

## What it does

1. Connects via managed identity to Microsoft Graph only (no EXO connect - see [Explicitly out of scope](#explicitly-out-of-scope)).
2. Skips cleanly if the UPN already exists (`SKIP`) - safe to re-run.
3. Creates the user via `New-MgUser` with a random temp password, `ForceChangePasswordNextSignIn = $false` by default, and all supplied profile fields (Department, JobTitle, Office Location, Company Name, etc.).
4. Sets the reporting manager via `Set-MgUserManagerByRef`.
5. **Optional** - validates and assigns a license (`-License`), checking spare seats first. If no seats are available, logs `MANUAL` and continues rather than failing the run. Leave `-License` blank to skip entirely.
6. **Optional** - emails a plain HTML actions-log summary to IT, via `-ITRecipients` / `-SenderMailbox`. Leave both blank to rely on the job's own Output log as the record instead.

Every step logs its own status (`OK`, `WHATIF`, `ERROR`, `SKIP`, `MANUAL`) to the job's Output log - your audit trail regardless of whether you use the summary email. The temp password is written there in clear text on a Live run, so it's readable directly (Automation Account job output is access-controlled). It's deliberately **redacted from the summary email** - the email will show "(redacted - see runbook Output log)" instead, so the password is never sent over email.

## Explicitly out of scope

- **`ForceChangePasswordNextSignIn` defaults to `$false`.** This assumes an admin (not the new hire) signs in first - e.g. to run device/Autopilot setup - so forcing a password change on next sign-in would just be friction for that admin, not the end user. If your new hires sign in themselves first, change the hardcoded `$false` in the `New-MgUser` call to `$true` (or add it as a parameter).
- **Temporary Access Pass (TAP)** - not built in. There's no universal convention for when/how orgs want to issue a TAP, so add your own step if needed.
- **Welcome/day-one email to the new hire** - not built in. Only an optional internal summary email to IT is included (step 6 above). Add your own new-hire-facing email if wanted.
- **Direct Enterprise Application assignment** - not built in. Add a step mirroring `Offboarding_Basic.ps1`'s app-removal logic (in reverse) if your org assigns apps directly rather than through group membership.
- **Manual group-add** - if your tenant uses dynamic security/M365 groups keyed off attributes like Department, those resolve on their own once the user is created with the right attributes - nothing to do here. **Static/assigned groups and on-prem-synced groups are NOT handled** - add manually or extend the script if your org uses them.
- **Exchange-specific mailbox setup / Exchange Online connection** - mailbox type is left as the default `User`; this runbook makes no EXO calls at all, unlike offboarding.
- **License-to-Department inference** - license assignment is a deliberate manual/optional choice per run, not inferred from Department/JobTitle. Add a lookup table yourself if your org's licensing rules are consistent enough to automate.
- **Bulk/array input** - single-run, single-user design (Start blade params). Wrap this script in your own loop over an array if you need to onboard many users in one run.

## Safety switch

`-RunMode` defaults to `DryRun` - every action is simulated and logged, nothing actually changes. Only `-RunMode Live` (must match that exact string) performs real changes. **Always run DryRun first** and review the Output log before ever running Live.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `UserPrincipalName` | Yes | The new hire's UPN/email address. |
| `FirstName` | Yes | New hire's first name. |
| `LastName` | Yes | New hire's last name. |
| `DisplayName` | Yes | Full display name, e.g. "Jane Doe". |
| `ManagerUpn` | No | Manager's UPN, e.g. `john.manager@contoso.com`. Must be a UPN or object ID - `Get-MgUser -UserId` does not accept a display name. |
| `JobTitle` | No | e.g. "Financial Analyst". |
| `Department` | No | Free text - set this to whatever your tenant's department taxonomy uses. If your tenant has dynamic groups keyed off Department, an unexpected/misspelled value here means the new hire won't land in the groups they should. |
| `OfficeLocation` | No | e.g. "Head Office". |
| `CompanyName` | No | e.g. "Contoso Ltd". |
| `UsageLocation` | No | ISO 3166-1 alpha-2 code. Required by Graph before any license can be assigned (even later, manually) - set this regardless of whether `-License` is supplied now. Defaults to `MY` in the script - change this default to your own org's primary location, or always pass it explicitly if your org spans multiple locations. |
| `License` | No | `SkuPartNumber`. Leave blank to skip license assignment entirely (logged as `SKIP` - assign manually later). Common SKUs for reference: `SPE_E5` (Microsoft 365 E5), `SPB` (Business Premium), `O365_BUSINESS_ESSENTIALS` (Business Basic), `Microsoft_365_Copilot` (add-on). Run this first to check your own tenant's available SKUs and spare seats: `Get-MgSubscribedSku \| Select-Object SkuPartNumber, ConsumedUnits, @{Name='Enabled';Expression={$_.PrepaidUnits.Enabled}}` |
| `ITRecipients` | No | Comma/semicolon-separated email address(es) to receive the summary email. Leave blank to skip the email entirely. |
| `SenderMailbox` | No | Mailbox the summary email is sent from (must be a real mailbox in the tenant). Required only if `ITRecipients` is set. |
| `RunMode` | No | `DryRun` (default) or `Live`. |

## Setup

### 1. Automation Account + managed identity

1. Create (or reuse) an Automation Account.
2. **Identity** (under Account Settings) → **System assigned** → Status **On** → Save.
3. Note the **Object (principal) ID** shown here - you'll need it below.

### 2. Import required modules

Under **Modules**, import (PowerShell 7.2 runtime):
- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Users`
- `Microsoft.Graph.Users.Actions`
- `Microsoft.Graph.Identity.DirectoryManagement`

No `ExchangeOnlineManagement` needed - this runbook makes no Exchange Online calls.

### 3. Grant Microsoft Graph permissions to the managed identity

There's no Azure Portal UI for granting Graph API permissions to a managed identity (unlike App Registrations) - it must be done via PowerShell, run once by someone with **Privileged Role Administrator** or **Global Administrator** (Cloud Application Administrator is *not* sufficient for this specific cmdlet, even though it's enough to grant admin consent for regular app registrations through the Entra admin center UI).

```powershell
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All"

$managedIdentityObjectId = "<Object ID from step 1>"
$graphAppId = "00000003-0000-0000-c000-000000000000"   # Microsoft Graph's well-known app ID
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'" -Property Id,AppRoles

$permissions = @(
    "User.ReadWrite.All",       # user creation, manager assignment
    "Directory.Read.All",       # manager lookups
    "Organization.Read.All",    # Get-MgSubscribedSku - only needed if you use -License
    "Mail.Send"                 # only needed if you use the optional summary email
)

foreach ($perm in $permissions) {
    $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $perm -and $_.AllowedMemberTypes -contains "Application" }
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentityObjectId `
        -PrincipalId $managedIdentityObjectId -ResourceId $graphSp.Id -AppRoleId $appRole.Id
}
```

Always fetch `$graphSp` with `-Property Id,AppRoles` explicitly, as shown above - fetching it via a plain `-Filter` without that property sometimes doesn't hydrate the `AppRoles` collection, which silently no-ops the assignment (no error, just nothing happens) instead of failing loudly.

Verify:

```powershell
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentityObjectId | Select-Object AppRoleId, ResourceDisplayName
```

You should see 4 Microsoft Graph entries (fewer if you skip `-License` or the summary email permanently and don't grant those two).

### 4. Publish and test

1. Paste this script into a new runbook (PowerShell 7.2 runtime) and **Publish** it.
2. Click **Start**, fill in the required fields, leave `License` blank for the first test, keep `RunMode = DryRun`.
3. Review the Output log line by line - every step should show `WHATIF` or a harmless real status, no unexpected `ERROR` entries.
4. Only once a DryRun looks clean, run again with `RunMode = Live` against a real new hire (ideally test against a disposable/test account first).
5. Before your first `-License` run, confirm `Organization.Read.All` is granted - otherwise `Get-MgSubscribedSku` will error and the step will log `ERROR` rather than `MANUAL`.

## Gotchas

- **No Portal UI for granting Graph permissions to a managed identity.** Enterprise Applications → Security → Permissions is read-only for managed identities - you can *view* what's granted there, but adding permissions requires PowerShell (or Graph Explorer/Azure CLI).
- **Cloud Application Administrator isn't enough** to run `New-MgServicePrincipalAppRoleAssignment`, even though it's enough to grant admin consent through the Entra admin center's UI for regular app registrations. You need Privileged Role Administrator or Global Administrator.
- **`Department` must match whatever your dynamic-group rules expect.** A typo or unlisted value here silently means the new hire is missing from whatever group rules key off it - there's no error, the rule just never matches them.
- **License seat checks are a point-in-time read.** Two onboarding runs started close together could both see the same "spare seat" and race for it - low risk at typical onboarding volumes, but worth knowing if you run this at scale or in parallel.
- **Azure Automation Metrics don't include a "job runtime minutes" metric.** The only metrics available are Hybrid Worker Ping, Total Jobs, Total Update Deployment Machine/Runs - none report duration. To check actual job runtime, look at the **Jobs** blade's start/end times, or Cost Management → Cost analysis filtered to the Automation service, viewed by usage quantity rather than cost.
- **Some subscription types (e.g. CSP-resold) may not include the standard 500 free job-runtime minutes/month** - if you see charges appear well before 500 minutes of usage, check your rate plan rather than assuming something's misconfigured.

## Customizing

- `$ForceChangePasswordNextSignIn` (hardcoded to `$false` in the `New-MgUser` call) - change to `$true` if your new hires sign in themselves first rather than an admin.
- The license SkuPartNumber list in the `.PARAMETER License` comment and the inline comment above the license-assignment step - update with whatever SKUs your tenant actually uses.
- `$UsageLocation`'s default (`'MY'` in the param block) - change to your own org's primary ISO country code.
- The IT summary email's HTML/branding, in the "OPTIONAL - actions-log summary email" section near the bottom - change colors, add a logo, adjust wording, or delete the whole block if you don't want it.
- Add a group-add, Enterprise Application assignment, TAP, or new-hire welcome-email step if your org's onboarding needs any of those - see [Explicitly out of scope](#explicitly-out-of-scope) for what's deliberately not included.

## License

Use, modify, and adapt freely.
