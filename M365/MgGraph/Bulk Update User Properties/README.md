# Bulk Update User Department (Microsoft Graph)

A PowerShell script to bulk-update the `Department` attribute for Entra ID users based on a mapping table, with a built-in dry-run mode and CSV reporting.

## What it does

- Connects to Microsoft Graph (requires `User.ReadWrite.All`)
- Looks up all users whose current `Department` matches a key in `$departmentMap`
- Updates each matching user's department to the mapped value
- Exports a CSV report of every change (or proposed change, in dry-run mode)

## Requirements

- [Microsoft.Graph PowerShell SDK](https://learn.microsoft.com/powershell/microsoftgraph/installation)
- Permission scope: `User.ReadWrite.All`
- PowerShell 7+ recommended

## Usage

1. Open the script and edit `$departmentMap` with your old → new department name pairs:
   ```powershell
   $departmentMap = @{
       "Sales"     = "Revenue"
       "Marketing" = "Growth"
   }
   ```
2. Leave `$dryRun = $true` for the first run. This will **not** make any changes — it only previews what would happen and writes `DeptChange_DryRun.csv`.
3. Connect to Graph:
   ```powershell
   Connect-MgGraph -Scopes "User.ReadWrite.All"
   ```
4. Run the script and review the console output and CSV.
5. Once you're confident the mapping is correct, set `$dryRun = $false` and run again to apply the changes. This produces `DeptChange_Applied.csv`.

## Output

Each run generates a CSV with:

| Column | Description |
|---|---|
| DisplayName | User's display name |
| UPN | User principal name |
| OldDepartment | Department before the change |
| NewDepartment | Department after the change (or proposed) |
| Status | `Pending` (dry run) or `Updated` (applied) |

## Notes / Disclaimer

- **Always run with `$dryRun = $true` first** and review the CSV before applying.
- Only users with a non-null `Department` matching a key in `$departmentMap` are affected — everyone else is skipped.
- No rollback is built in. Keep the dry-run CSV as your record of prior state if you need to revert manually.
- Test in a non-production tenant or on a small user sample if possible before running tenant-wide.
