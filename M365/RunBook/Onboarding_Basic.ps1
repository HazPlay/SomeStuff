<#
.SYNOPSIS
    Azure Automation runbook - onboard a new hire in Microsoft 365 (Entra ID). Generic/public
    version, no organization-specific values.

.DESCRIPTION
    Companion to Offboarding_Basic.ps1, built for the same Azure Automation Account and
    system-assigned managed identity - no passwords, secrets, or certificates stored anywhere.

    Scoped to Entra ID account creation + manager + license only. No Exchange Online calls
    (mailbox stays default type, nothing EXO-specific needed at onboarding), no Temporary
    Access Pass, no welcome/day-one email, no Enterprise Application assignment, no manual
    group-add. Single-run, single-user design (Start blade params) - bring your own bulk/array
    wrapper if you need to onboard many users at once.

    Sequence:
      1. Connect (managed identity) to Microsoft Graph.
      2. Skip cleanly if the UPN already exists (safe to re-run).
      3. Create the user with a random temp password, ForceChangePasswordNextSignIn = $false.
      4. Set the reporting manager (optional).
      5. Optional: validate and assign a license, checking spare seats first. No seats -> logs
         MANUAL and continues rather than failing the run. Blank -License -> SKIP entirely.
      6. Optional: email a plain actions-log summary to IT (sent only if -ITRecipients and
         -SenderMailbox are both non-blank; leave both blank to skip entirely and rely on the
         job's own Output log instead).

    Design notes:
      - ForceChangePasswordNextSignIn defaults to $false. This assumes an admin (not the new
        hire) is the first person to sign into the account - e.g. to run device/Autopilot
        setup - so forcing a password change on first sign-in would just be friction for that
        admin. If your new hires sign in themselves first, change this to $true. Either way,
        the temp password is surfaced in the runbook's Output log in clear text (Automation
        Account job output is access-controlled) so whoever needs it can read it there - it is
        deliberately redacted from the optional summary email (see step 6) so it's never sent
        over email.
      - Temporary Access Pass (TAP) is OUT of scope - add it yourself if your onboarding flow
        needs one; there's no universal convention for when/how orgs want to issue it.
      - No welcome/day-one email to the new hire - only an optional internal summary email to
        IT is included (step 6). Add your own new-hire-facing email if wanted.
      - Mailbox type is left as default (User) - no Exchange-specific setup step, and no EXO
        connection is made at all in this runbook.
      - No direct Enterprise Application assignment step - add one (mirroring
        Offboarding_Basic.ps1's app-removal logic, in reverse) if your org assigns apps
        directly rather than through group membership.
      - No manual group-add step. If your tenant uses dynamic security/M365 groups keyed off
        attributes like Department, those resolve on their own once the user is created with
        the right attributes - nothing to do here. Static/assigned groups and on-prem-synced
        groups are NOT handled by this script and need separate handling if your org uses them.
      - License assignment is OPTIONAL and skippable by design - it's a per-user judgment call
        (seat availability, role) that this script deliberately does NOT try to infer from
        Department/JobTitle, since that logic varies heavily by org. Leave -License blank to
        skip and assign later; if supplied, the script validates the SKU exists and has spare
        seats before assigning, and will not fail the whole run if seats are unavailable (logs
        MANUAL and continues).

.NOTES
    Runtime: PowerShell 7.2+
    Required module imported into the Automation account: Microsoft.Graph (Users,
    Users.Actions, Identity.DirectoryManagement).
    Permissions to grant the managed identity are listed in README.md.

    Run this once with -RunMode DryRun (the default) to simulate before running -RunMode Live.

.PARAMETER UserPrincipalName
    New hire's UPN / sign-in email, e.g. "jane.doe@contoso.com". This is the field you fill in
    on the Start blade.

.PARAMETER FirstName
    New hire's first name.

.PARAMETER LastName
    New hire's last name.

.PARAMETER DisplayName
    Full display name, e.g. "Jane Doe".

.PARAMETER ManagerUpn
    Manager's UPN, e.g. "john.manager@contoso.com". Must be a UPN or object ID - Get-MgUser's
    -UserId parameter does not accept a display name.

.PARAMETER JobTitle
    e.g. "Financial Analyst".

.PARAMETER Department
    Free text - set this to whatever your tenant's department taxonomy uses. If your tenant
    has dynamic groups keyed off Department, an unexpected/misspelled value here means the new
    hire won't land in the groups they should.

.PARAMETER OfficeLocation
    e.g. "Head Office".

.PARAMETER CompanyName
    e.g. "Contoso Ltd".

.PARAMETER UsageLocation
    ISO 3166-1 alpha-2 code. Required by Graph before any license can be assigned (even later,
    manually) - set on every user regardless of whether -License is supplied now. Defaults to
    "MY" (Malaysia) - change this default to match your own org's primary location, or always
    pass it explicitly if your org spans multiple locations.

.PARAMETER License
    Optional. SkuPartNumber, e.g. "SPE_E5". Leave blank to skip license assignment entirely
    (logged as SKIP - assign manually later). SkuPartNumber is Microsoft's internal code and
    doesn't match the plan name shown in the admin center - some common ones for reference:
      SPE_E5                   = Microsoft 365 E5
      SPB                      = Microsoft 365 Business Premium
      O365_BUSINESS_ESSENTIALS = Microsoft 365 Business Basic
      Microsoft_365_Copilot    = Microsoft 365 Copilot (add-on - stacks on top of a base
                                  license, not a standalone seat)
    Run this first to check your own tenant's available SkuPartNumbers and spare seats before
    supplying a value:

        Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, @{Name='Enabled';Expression={$_.PrepaidUnits.Enabled}}

.PARAMETER ITRecipients
    Comma/semicolon-separated email address(es) that receive the actions-log summary email.
    Leave blank (along with -SenderMailbox) to skip the email entirely and rely on the job's
    own Output log as the record.

.PARAMETER SenderMailbox
    Mailbox the summary email is sent FROM (must be a real, licensed/shared mailbox in the
    tenant). Only used if -ITRecipients is set.

.PARAMETER RunMode
    SAFETY SWITCH. 'DryRun' (default) - simulates every step, no changes made, logged as
    WHATIF. 'Live' - performs the actual actions. Must be typed/selected exactly as 'Live' to
    act for real.

.EXAMPLE
    # Dry run - preview only, no changes made (UsageLocation defaults to "MY")
    .\Onboarding_Basic.ps1 -FirstName "Jane" -LastName "Doe" -DisplayName "Jane Doe" `
        -UserPrincipalName "jane.doe@contoso.com" -ManagerUpn "john.manager@contoso.com" `
        -JobTitle "Financial Analyst" -Department "Finance" -OfficeLocation "Head Office" `
        -CompanyName "Contoso Ltd"

.EXAMPLE
    # Live run, with license assignment and an IT summary email
    .\Onboarding_Basic.ps1 -RunMode Live -FirstName "Jane" -LastName "Doe" `
        -DisplayName "Jane Doe" -UserPrincipalName "jane.doe@contoso.com" `
        -ManagerUpn "john.manager@contoso.com" -JobTitle "Financial Analyst" `
        -Department "Finance" -OfficeLocation "Head Office" -CompanyName "Contoso Ltd" `
        -License "SPE_E5" -ITRecipients "it@contoso.com" -SenderMailbox "automation@contoso.com"

.EXAMPLE
    # Different UsageLocation, no IT summary email
    .\Onboarding_Basic.ps1 -RunMode Live -FirstName "John" -LastName "Lee" `
        -DisplayName "John Lee" -UserPrincipalName "john.lee@contoso.com" `
        -UsageLocation "HK"
#>

param(
    # The new hire's email address - this is the field you fill in on the Start blade.
    [Parameter(Mandatory = $true)]
    [string] $UserPrincipalName,

    [Parameter(Mandatory = $true)] [string] $FirstName,
    [Parameter(Mandatory = $true)] [string] $LastName,
    [Parameter(Mandatory = $true)] [string] $DisplayName,

    [string] $ManagerUpn = '',
    [string] $JobTitle = '',
    [string] $Department = '',
    [string] $OfficeLocation = '',
    [string] $CompanyName = '',

    # Change this default to match your own org's primary location, or always pass it
    # explicitly if your org spans multiple locations.
    [string] $UsageLocation = 'MY',

    # OPTIONAL - SkuPartNumber, e.g. "SPE_E5". Leave blank to skip license assignment entirely.
    [string] $License = '',

    # IT address(es) that receive the actions-log summary email. Leave blank (along with
    # -SenderMailbox) to skip the email entirely and rely on the job's own Output log instead.
    [string] $ITRecipients = '',

    # Mailbox the summary is sent FROM (must be a real, licensed/shared mailbox in the
    # tenant). Only used if -ITRecipients is provided.
    [string] $SenderMailbox = '',

    # SAFETY SWITCH. 'DryRun' = simulate only, makes NO changes (default).
    # 'Live' = perform real changes. Must be typed/selected exactly as 'Live' to act for real.
    [ValidateSet('DryRun', 'Live')]
    [string] $RunMode = 'DryRun'
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()

# Fail-safe: anything other than the exact string 'Live' is treated as a dry run.
# Using a validated text value avoids unreliable boolean parameter binding in Azure Automation.
$WhatIfMode = ($RunMode -ne 'Live')

function Add-Result {
    param([string]$Step, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Time = (Get-Date).ToString('s'); Step = $Step; Status = $Status; Detail = $Detail })
    Write-Output ("[{0,-6}] {1} :: {2}" -f $Status, $Step, $Detail)
}

function Should-Run {
    # IMPORTANT: must return ONLY a boolean. Do NOT Write-Output here - in PowerShell a function
    # returns everything it emits to the pipeline, so a Write-Output line would make this return
    # an array (string + bool), which 'if (Should-Run ...)' treats as TRUE and runs live actions
    # even during a dry run. Returning a clean boolean is what makes DryRun actually safe.
    param([string]$Action)
    if ($WhatIfMode) { return $false } else { return $true }
}

$ScriptVersion = '1.0'
$upn = $UserPrincipalName
Write-Output "=== Onboarding $upn  (script version $ScriptVersion) ==="
$modeText = if ($WhatIfMode) { 'DRY RUN - no changes will be made' } else { 'LIVE - real changes WILL be made' }
Write-Output ("RunMode received: '{0}'  ->  {1}" -f $RunMode, $modeText)

# ----------------------------------------------------------------------------------------
# Connect with the MANAGED IDENTITY - no stored secrets. Microsoft Graph only - this runbook
# makes no Exchange Online calls (mailbox stays default type at onboarding).
# ----------------------------------------------------------------------------------------
try {
    Connect-MgGraph -Identity -NoWelcome
    Add-Result 'Connect-Graph' 'OK' 'Connected via managed identity'
}
catch { Add-Result 'Connect-Graph' 'ERROR' $_.Exception.Message; throw }

# ----------------------------------------------------------------------------------------
# 1. Skip cleanly if the account already exists - safe to re-run
# ----------------------------------------------------------------------------------------
$existing = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
if ($existing) {
    Add-Result 'CreateUser' 'SKIP' "$upn already exists (Id: $($existing.Id))"
}
else {
    # ------------------------------------------------------------------------------------
    # 2. Create the user
    # ------------------------------------------------------------------------------------
    # Every profile field supplied, logged as its own row below (Add-Profile-Result), so the
    # log/report shows exactly what's being set on the account, not just the display name.
    $profileFields = [ordered]@{
        FirstName      = $FirstName
        LastName       = $LastName
        DisplayName    = $DisplayName
        JobTitle       = $JobTitle
        Department     = $Department
        OfficeLocation = $OfficeLocation
        CompanyName    = $CompanyName
        UsageLocation  = $UsageLocation
    }
    function Add-Profile-Result {
        param([string]$Status)
        foreach ($f in $profileFields.GetEnumerator()) {
            if ($f.Value) { Add-Result "Profile-$($f.Key)" $Status $f.Value }
        }
    }

    if (Should-Run "Create $upn") {
        try {
            $chars = (48..57) + (65..90) + (97..122)
            $password = (-join (1..20 | ForEach-Object { [char]($chars | Get-Random) })) + 'Aa1!'
            $mailNickname = ($upn -split '@')[0]

            $newUserParams = @{
                AccountEnabled    = $true
                DisplayName       = $DisplayName
                GivenName         = $FirstName
                Surname           = $LastName
                MailNickname      = $mailNickname
                UserPrincipalName = $upn
                PasswordProfile   = @{
                    Password                      = $password
                    ForceChangePasswordNextSignIn = $false
                }
            }
            if ($JobTitle)       { $newUserParams.JobTitle = $JobTitle }
            if ($Department)     { $newUserParams.Department = $Department }
            if ($OfficeLocation) { $newUserParams.OfficeLocation = $OfficeLocation }
            if ($CompanyName)    { $newUserParams.CompanyName = $CompanyName }
            if ($UsageLocation)  { $newUserParams.UsageLocation = $UsageLocation }

            $newUser = New-MgUser @newUserParams
            $newUserId = $newUser.Id
            Add-Result 'CreateUser' 'OK' "Created $upn (Id: $newUserId). Temp password: $password"
            Add-Profile-Result 'OK'
        }
        catch { Add-Result 'CreateUser' 'ERROR' $_.Exception.Message }
    }
    else {
        Add-Result 'CreateUser' 'WHATIF' "Would create $upn"
        Add-Profile-Result 'WHATIF'
    }

    # ------------------------------------------------------------------------------------
    # 3. Set manager (optional)
    # ------------------------------------------------------------------------------------
    if (-not $ManagerUpn) {
        Add-Result 'SetManager' 'SKIP' 'No ManagerUpn supplied'
    }
    elseif (Should-Run "Set manager to $ManagerUpn") {
        try {
            $manager = Get-MgUser -UserId $ManagerUpn -ErrorAction Stop
            $managerRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($manager.Id)" }
            Set-MgUserManagerByRef -UserId $newUserId -BodyParameter $managerRef
            Add-Result 'SetManager' 'OK' "Manager set to $ManagerUpn"
        }
        catch { Add-Result 'SetManager' 'ERROR' $_.Exception.Message }
    }
    else {
        Add-Result 'SetManager' 'WHATIF' "Would set manager to $ManagerUpn"
    }

    # ------------------------------------------------------------------------------------
    # 4. Assign license (optional, skippable)
    #    SkuPartNumber -> plan name (common SKUs, for reference - not exhaustive):
    #      SPE_E5                   = Microsoft 365 E5
    #      SPB                      = Microsoft 365 Business Premium
    #      O365_BUSINESS_ESSENTIALS = Microsoft 365 Business Basic
    #      Microsoft_365_Copilot    = Microsoft 365 Copilot (add-on, not a standalone seat)
    # ------------------------------------------------------------------------------------
    if (-not $License) {
        Add-Result 'AssignLicense' 'SKIP' 'No License specified - assign manually if required'
    }
    elseif (Should-Run "Assign license $License") {
        try {
            $sku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq $License }
            if (-not $sku) { throw "SKU '$License' not found in this tenant" }
            $spare = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
            if ($spare -le 0) {
                Add-Result 'AssignLicense' 'MANUAL' "No spare seats for $License (0 available) - assign manually once seats free up"
            }
            else {
                Set-MgUserLicense -UserId $newUserId -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @()
                Add-Result 'AssignLicense' 'OK' "Assigned $License ($spare seats were spare before assignment)"
            }
        }
        catch { Add-Result 'AssignLicense' 'ERROR' $_.Exception.Message }
    }
    else {
        Add-Result 'AssignLicense' 'WHATIF' "Would assign license $License"
    }
}

# ----------------------------------------------------------------------------------------
# 6. OPTIONAL - actions-log summary email to IT. Only sent if both -ITRecipients and
#    -SenderMailbox are non-blank; otherwise the job's own Output log (console above) is
#    the record.
# ----------------------------------------------------------------------------------------
$itList = @($ITRecipients -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($itList.Count -gt 0 -and $SenderMailbox) {
    $errorItems = $results | Where-Object Status -eq 'ERROR'
    $dateLong = Get-Date -Format 'dd MMMM yyyy'
    $mode = if ($WhatIfMode) { ' (DRY RUN - no changes were made)' } else { '' }
    $subjectPrefix = if ($WhatIfMode) { '[DRY RUN] ' } else { '' }

    $rowsHtml = ($results | ForEach-Object {
            $bg = switch ($_.Status) { 'OK' { '#e6f4ea' } 'AUTO' { '#e1f5ee' } 'MANUAL' { '#e7f0fd' } 'ERROR' { '#fce8e6' } 'WHATIF' { '#f1f3f4' } default { '#fff8e1' } }
            # Redact the temp password from the emailed summary only - it still appears in
            # full in the runbook's Output log (job output is access-controlled), so it's
            # readable there without exposing it over email.
            $emailDetail = $_.Detail -replace 'Temp password: \S+', 'Temp password: (redacted - see runbook Output log)'
            "<tr bgcolor='$bg'><td style='padding:6px 10px;font-size:12px;color:#2b2b2b;border-bottom:1px solid #e5e7eb;'>$($_.Step)</td><td style='padding:6px 10px;font-size:12px;color:#2b2b2b;border-bottom:1px solid #e5e7eb;'>$($_.Status)</td><td style='padding:6px 10px;font-size:12px;color:#2b2b2b;border-bottom:1px solid #e5e7eb;'>$emailDetail</td></tr>"
        }) -join "`n"

    $itBody = @"
<table width="100%" cellpadding="0" cellspacing="0" style="background-color:#f1f1f1;"><tr><td align="center" style="padding:20px 0;">
<table width="880" cellpadding="0" cellspacing="0" style="background-color:#ffffff;font-family:Arial,Helvetica,sans-serif;">
  <tr><td bgcolor="#1f3a5c" style="padding:22px 28px;">
    <div style="font-size:19px;font-weight:bold;color:#ffffff;">M365 Onboarding Completed$mode</div>
    <div style="font-size:13px;color:#a9b8c9;padding-top:4px;">$dateLong</div>
  </td></tr>
  <tr><td style="padding:26px 28px;color:#2b2b2b;font-size:14px;">
    <p style="margin:0 0 10px;line-height:1.6;">The automated M365 onboarding routine has completed for <b>$DisplayName</b> ($upn). Errors: <b>$($errorItems.Count)</b>.</p>
    <table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">
      <tr bgcolor="#1f3a5c">
        <td width="30%" style="padding:8px 10px;color:#ffffff;font-size:12px;font-weight:bold;">Step</td>
        <td width="16%" style="padding:8px 10px;color:#ffffff;font-size:12px;font-weight:bold;">Status</td>
        <td style="padding:8px 10px;color:#ffffff;font-size:12px;font-weight:bold;">Detail</td>
      </tr>
      $rowsHtml
    </table>
    <p style="font-size:12px;color:#9aa0a6;font-style:italic;margin:18px 0 0;">This is an automated message.</p>
  </td></tr>
</table>
</td></tr></table>
"@

    try {
        $itMsg = @{
            subject      = ($subjectPrefix + "M365 Onboarding Completed: $DisplayName$mode")
            body         = @{ contentType = 'HTML'; content = $itBody }
            toRecipients = @($itList | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
        }
        Send-MgUserMail -UserId $SenderMailbox -Message $itMsg -SaveToSentItems:$false
        Add-Result 'Notify-IT' 'OK' ("Actions log emailed to {0}{1}" -f ($itList -join ', '), $(if ($WhatIfMode) { ' [DRY RUN]' } else { '' }))
    }
    catch { Add-Result 'Notify-IT' 'ERROR' $_.Exception.Message }
}
else {
    Add-Result 'Notify-IT' 'SKIP' 'No ITRecipients/SenderMailbox provided - relying on the job Output log as the record'
}

# Final job-log summary
Write-Output "`n=== Summary ==="
$results | Group-Object Status | ForEach-Object { Write-Output (" {0,-7}: {1}" -f $_.Name, $_.Count) }
$errorItems = $results | Where-Object Status -eq 'ERROR'
if ($errorItems) { Write-Output ("ERRORS: {0} - review the actions log" -f $errorItems.Count) }

$results
Disconnect-MgGraph | Out-Null
