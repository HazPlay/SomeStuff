# Get-SharedMailboxReport

A single PowerShell script that connects to Exchange Online, pulls **Full Access** and **Send As** delegates for every shared mailbox, and generates a self-contained, interactive HTML report — no external dependencies, works fully offline once generated.

Click a mailbox row to expand its delegates. Filter by GAL visibility, never-logged-on mailboxes, or mailboxes with no delegates. Search matches mailbox name/email/alias or a delegate's display name/UPN.

## Requirements

- [ExchangeOnlineManagement](https://www.powershellgallery.com/packages/ExchangeOnlineManagement) module
  ```powershell
  Install-Module ExchangeOnlineManagement -Scope CurrentUser
  ```
- An account with permission to read mailbox permissions in your tenant (e.g. Exchange Recipient Administrator or higher).

## Usage

Run it as a script:

```powershell
.\Get-SharedMailboxReport.ps1 -OutputPath "C:\Reports" -OpenAfterExport
```

Or just copy/paste the entire contents into a PowerShell terminal (VS Code integrated terminal, `pwsh`, `powershell.exe`, etc.) and run it directly — no need to save it as a file first.

You'll be prompted to sign in to Exchange Online if you don't already have an active session. The report is written to the current directory unless `-OutputPath` is specified.

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `-OutputPath` | No | Folder to save the HTML report to. Defaults to the current directory. |
| `-CsvPath` | No | If set, also exports a flat CSV backup of the same data (one row per mailbox/delegate). |
| `-OpenAfterExport` | No | Switch. Opens the HTML report automatically once it's generated. |

## Branding

The report title includes a company name placeholder. To personalize it, open the script and edit **line 270**:

```html
<div class="subtitle">Generated $generatedOn &nbsp;|&nbsp; Your Company &nbsp;|&nbsp; $mailboxCount shared mailboxes</div>
```

Replace `Your Company` with your own organization's name.

## A note on the output

The script itself contains no tenant-specific data, credentials, or identifiers — it's safe to share as-is. The **generated HTML/CSV reports are not**: they contain real mailbox names, delegate identities, and usage data from whichever tenant you run it against. Don't commit report output to a public repository.
