#Requires -Version 7.0
<#
.SYNOPSIS
    GroupDesk — M365 Group Housekeeping Console

.DESCRIPTION
    Starts a local web server on localhost:8743 and opens a browser.
    Authenticates via Entra ID SSO (PKCE flow — no client secret needed).
    All Graph API calls are server-side; token stays in RAM and is cleared on exit.
    Write actions (add/remove members/owners) each require explicit confirmation.

.PARAMETER TenantId
    Your Entra tenant ID (GUID).

.PARAMETER ClientId
    App Registration client ID (GUID).

.PARAMETER Port
    Local port. Default: 8743.

.PARAMETER NoBrowser
    Do not open the browser automatically.

.PARAMETER StaleDays
    Days of inactivity before flagging M365 groups as stale. Default: 90.

.NOTES
    GroupDesk — MIT Licence
    Built by HazPlay (https://github.com/hazplay)

    App Registration setup (one-time):
      1. Entra Admin Center → App registrations → New registration
      2. Name: GroupDesk (or any name you like)
      3. Supported account types: Accounts in this organisational directory only
      4. Platform: Mobile and desktop applications
         Redirect URI: http://localhost:<PORT>/callback  (replace <PORT> with your chosen port)
      5. API permissions → Add delegated permissions:
           Group.Read.All
           GroupMember.ReadWrite.All
           Group.ReadWrite.All
           User.Read.All
           Reports.Read.All      (optional — enables activity-based stale detection)
      6. Grant admin consent for your organisation
      7. Enterprise Applications → your app → Properties
         → User assignment required: Yes
      8. Enterprise Applications → your app → Users and groups
         → Add the users or groups who should have access

    Run with:
      pwsh .\groupdesk.ps1 -TenantId "YOUR-TENANT-ID" -ClientId "YOUR-CLIENT-ID"

.EXAMPLE
    pwsh .\groupdesk.ps1 -TenantId "YOUR-TENANT-ID" -ClientId "YOUR-CLIENT-ID"
#>

# MIT Licence
# Copyright (c) 2026 HazPlay
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [int]$Port      = 8743,
    [switch]$NoBrowser,
    [int]$StaleDays = 90
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Web   # for [System.Web.HttpUtility]::HtmlEncode

# ─── Global state ─────────────────────────────────────────────────────────────
$script:TenantId     = $TenantId
$script:ClientId     = $ClientId
$script:Port         = $Port
$script:StaleDays    = $StaleDays
$script:BaseUrl      = 'https://graph.microsoft.com/v1.0'

$script:Token        = $null
$script:RefreshToken = $null
$script:TokenExpiry  = [datetime]::MinValue
$script:Me           = $null
$script:CodeVerifier = $null
$script:AuthState    = $null

$script:GroupCache   = $null
$script:UserCache    = @{}
$script:LoadProgress = @{ status = 'idle'; current = 0; total = 0; message = '' }
$script:ActionLog    = [System.Collections.Generic.List[PSCustomObject]]::new()

# ─── Logging ──────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $ts = (Get-Date).ToString('HH:mm:ss')
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
    Write-Host "  [$ts] $Message" -ForegroundColor $color
}

# ─── PKCE helpers ─────────────────────────────────────────────────────────────
function New-CodeVerifier {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-CodeChallenge {
    param([string]$Verifier)
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($Verifier))
    $sha.Dispose()
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-AuthUrl {
    $challenge   = New-CodeChallenge $script:CodeVerifier
    $scopes      = 'Group.Read.All GroupMember.ReadWrite.All Group.ReadWrite.All User.Read.All Reports.Read.All openid profile email offline_access'
    $scopeEnc    = [Uri]::EscapeDataString($scopes)
    $redirectEnc = [Uri]::EscapeDataString("http://localhost:$script:Port/callback")
    return ("https://login.microsoftonline.com/$script:TenantId/oauth2/v2.0/authorize" +
            "?client_id=$script:ClientId" +
            "&response_type=code" +
            "&redirect_uri=$redirectEnc" +
            "&scope=$scopeEnc" +
            "&code_challenge=$challenge" +
            "&code_challenge_method=S256" +
            "&state=$script:AuthState" +
            "&prompt=select_account")
}

# ─── Token management ─────────────────────────────────────────────────────────
function Update-Token {
    param([string]$Code, [switch]$UseRefresh)
    $redirectUri = "http://localhost:$script:Port/callback"
    $body = if ($UseRefresh) {
        @{ grant_type    = 'refresh_token'
           client_id     = $script:ClientId
           refresh_token = $script:RefreshToken
           scope         = 'Group.Read.All GroupMember.ReadWrite.All Group.ReadWrite.All User.Read.All Reports.Read.All openid profile email offline_access' }
    } else {
        @{ grant_type    = 'authorization_code'
           client_id     = $script:ClientId
           code          = $Code
           redirect_uri  = $redirectUri
           code_verifier = $script:CodeVerifier }
    }
    $uri  = "https://login.microsoftonline.com/$script:TenantId/oauth2/v2.0/token"
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Body $body `
                -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop

    $script:Token       = $resp.access_token
    $script:TokenExpiry = (Get-Date).AddSeconds([int]$resp.expires_in - 60)
    if ($resp.PSObject.Properties['refresh_token']) {
        $script:RefreshToken = $resp.refresh_token
    }
}

function Get-ValidToken {
    if (-not $script:Token) { throw 'Not authenticated.' }
    if ((Get-Date) -ge $script:TokenExpiry -and $script:RefreshToken) {
        Update-Token -UseRefresh
    }
    return $script:Token
}

# ─── Graph request helper ─────────────────────────────────────────────────────
function Invoke-Graph {
    param(
        [string]$Uri,
        [string]$Method  = 'GET',
        [object]$Body,
        [switch]$All,
        [switch]$Raw,
        [hashtable]$ExtraHeaders = @{}
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $next  = if ($Uri -match '^https://') { $Uri } else { "$script:BaseUrl$Uri" }

    do {
        $headers = @{ Authorization = "Bearer $(Get-ValidToken)" } + $ExtraHeaders
        $params  = @{
            Method                 = $Method
            Uri                    = $next
            Headers                = $headers
            SkipHttpErrorCheck     = $true
            StatusCodeVariable     = 'sc'
        }
        if ($Body) {
            $params.Body        = ($Body | ConvertTo-Json -Depth 10)
            $params.ContentType = 'application/json'
        }

        $resp = Invoke-RestMethod @params

        if ($sc -ge 400) {
            $detail = try { $resp.error.message } catch { "HTTP $sc" }
            throw "Graph $Method $Uri → $sc : $detail"
        }
        if ($Raw) { return $resp }

        if ($null -ne $resp -and $resp.PSObject.Properties['value']) {
            if ($resp.value) { $items.AddRange([object[]]@($resp.value)) }
            $next = if ($All -and $resp.PSObject.Properties['@odata.nextLink']) {
                        $resp.'@odata.nextLink'
                    } else { $null }
        } else {
            return $resp
        }
    } while ($next)

    return $items
}

# ─── Data loading ─────────────────────────────────────────────────────────────
function Load-AllData {
    $script:LoadProgress = @{ status = 'loading'; current = 0; total = 0; message = 'Fetching groups...' }
    Write-Log "Starting data load..." 'INFO'

    # ── Groups ────────────────────────────────────────────────────────────────
    $props = 'id,displayName,description,groupTypes,securityEnabled,mailEnabled,' +
             'membershipRule,createdDateTime,renewedDateTime,onPremisesSyncEnabled,' +
             'mail,resourceProvisioningOptions'
    $rawGroups = @(Invoke-Graph "/groups?`$select=$props&`$top=999" -All)
    Write-Log "$($rawGroups.Count) groups fetched" 'OK'

    # ── Activity report (M365 stale detection) ────────────────────────────────
    $activeGroupIds   = @{}
    $staleGroupIds    = @{}
    $reportsAvailable = $false
    try {
        $reportUri = "$script:BaseUrl/reports/getOffice365GroupsActivityDetail(period='D$script:StaleDays')"
        $reportRaw = Invoke-RestMethod -Uri $reportUri `
                         -Headers @{ Authorization = "Bearer $(Get-ValidToken)" } `
                         -SkipHttpErrorCheck -StatusCodeVariable rsc
        if ($rsc -lt 400 -and $reportRaw -and $reportRaw.value) {
            $cutoff = [datetime]::UtcNow.AddDays(-$script:StaleDays)
            foreach ($row in $reportRaw.value) {
                $gid = $row.'Group Id'
                if (-not $gid) { continue }
                $lastAct = $row.'Last Activity Date'
                if ($lastAct -and [datetime]::Parse($lastAct) -ge $cutoff) {
                    $activeGroupIds[$gid] = $true
                } else {
                    $staleGroupIds[$gid] = $true
                }
            }
            $reportsAvailable = $true
            Write-Log "Activity report: $($activeGroupIds.Count) active, $($staleGroupIds.Count) stale" 'OK'
        }
    } catch {
        Write-Log "Reports API unavailable — using renewedDateTime fallback" 'WARN'
    }

    # ── Users ─────────────────────────────────────────────────────────────────
    $script:LoadProgress.message = 'Loading users...'
    $uProps    = 'id,displayName,userPrincipalName,mail,accountEnabled,userType,department,companyName,jobTitle,officeLocation'
    $rawUsers  = @(Invoke-Graph "/users?`$select=$uProps&`$top=999" -All)
    $userMap   = @{}
    foreach ($u in $rawUsers) {
        $email    = if ($u.mail) { $u.mail }
                    elseif ($u.userPrincipalName -notmatch '#EXT#') { $u.userPrincipalName }
                    else { '' }
        $userMap[$u.id] = [PSCustomObject]@{
            id             = $u.id
            displayName    = $u.displayName
            email          = $email
            department     = $u.department
            companyName    = $u.companyName
            jobTitle       = $u.jobTitle
            officeLocation = $u.officeLocation
            isDisabled     = ($u.accountEnabled -ne $true)
            isGuest        = ($u.userType -eq 'Guest')
            isActive       = ($u.accountEnabled -eq $true) -and ($u.userType -ne 'Guest')
        }
    }
    $script:UserCache = $userMap
    Write-Log "$($rawUsers.Count) users loaded" 'OK'

    # Group name map for nested resolution
    $groupNameMap = @{}
    foreach ($g in $rawGroups) { $groupNameMap[$g.id] = $g.displayName }

    # ── Process each group ────────────────────────────────────────────────────
    $script:LoadProgress.total   = $rawGroups.Count
    $script:LoadProgress.message = "Processing groups..."
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $idx     = 0

    foreach ($grp in $rawGroups) {
        $idx++
        $script:LoadProgress.current = $idx
        $script:LoadProgress.message = "($idx/$($rawGroups.Count)) $($grp.displayName)"
        Write-Progress -Activity "Loading groups" -Status $grp.displayName `
                       -PercentComplete ([math]::Round(($idx / $rawGroups.Count) * 100))

        # Type classification
        $isDynamic = @($grp.groupTypes) -contains 'DynamicMembership'
        $isUnified = @($grp.groupTypes) -contains 'Unified'
        $hasTeam   = $isUnified -and (@($grp.resourceProvisioningOptions) -contains 'Team')

        $groupType = switch ($true) {
            ($isUnified -and $isDynamic)                      { 'DynamicM365';         break }
            ($isUnified)                                      { 'M365';                break }
            ($isDynamic)                                      { 'DynamicSecurity';     break }
            ($grp.securityEnabled -and $grp.mailEnabled)      { 'MailEnabledSecurity'; break }
            ($grp.securityEnabled -and -not $grp.mailEnabled) { 'Security';            break }
            ($grp.mailEnabled -and -not $grp.securityEnabled) { 'Distribution';        break }
            default                                           { 'Unknown' }
        }

        $groupCategory = switch ($groupType) {
            'M365'                { 'Microsoft 365'; break }
            'DynamicM365'         { 'Microsoft 365'; break }
            'Security'            { 'Security';      break }
            'DynamicSecurity'     { 'Security';      break }
            'MailEnabledSecurity' { 'Security';      break }
            'Distribution'        { 'Distribution';  break }
            default               { 'Unknown' }
        }

        $membershipType = if ($isDynamic) { 'Dynamic' } else { 'Assigned' }

        # Members
        $memberDetails    = [System.Collections.Generic.List[PSCustomObject]]::new()
        $nestedGroupNames = [System.Collections.Generic.List[string]]::new()

        try {
            $mProps   = 'id,displayName,userPrincipalName,accountEnabled,userType'
            $members  = @(Invoke-Graph "/groups/$($grp.id)/members?`$select=$mProps&`$top=999" -All)
            foreach ($m in $members) {
                $otype = if ($m.PSObject.Properties['@odata.type']) { $m.'@odata.type' } else { '' }
                if ($otype -eq '#microsoft.graph.group') {
                    $nestedGroupNames.Add(
                        $(if ($groupNameMap.ContainsKey($m.id)) { $groupNameMap[$m.id] } else { $m.id }))
                } elseif ($userMap.ContainsKey($m.id)) {
                    $u = $userMap[$m.id]
                    $memberDetails.Add([PSCustomObject]@{
                        id             = $u.id
                        displayName    = $u.displayName
                        email          = $u.email
                        department     = $u.department
                        companyName    = $u.companyName
                        jobTitle       = $u.jobTitle
                        officeLocation = $u.officeLocation
                        isDisabled     = $u.isDisabled
                        isGuest        = $u.isGuest
                        isActive       = $u.isActive
                    })
                }
            }
        } catch { }

        $activeMembers      = @($memberDetails | Where-Object { $_.isActive })
        $disabledMembers    = @($memberDetails | Where-Object { $_.isDisabled })
        $guestMembers       = @($memberDetails | Where-Object { $_.isGuest })

        # Owners
        $ownerDetails     = [System.Collections.Generic.List[PSCustomObject]]::new()
        $ownerSource      = if ($groupCategory -eq 'Distribution') { 'exchange' } else { 'graph' }
        $inactiveOwnerCount = 0

        if ($ownerSource -eq 'graph') {
            try {
                $ownerObjs = @(Invoke-Graph "/groups/$($grp.id)/owners?`$select=id,displayName" -All)
                foreach ($o in $ownerObjs) {
                    $oname = if ($o.PSObject.Properties['displayName']) { $o.displayName }
                             else { $o.AdditionalProperties.displayName }
                    if ($oname) {
                        $isInactiveOwner = $userMap.ContainsKey($o.id) -and ($userMap[$o.id].isDisabled -eq $true)
                        if ($isInactiveOwner) { $inactiveOwnerCount++ }
                        $ownerDetails.Add([PSCustomObject]@{
                            id            = $o.id
                            name          = $oname
                            isDisabled    = $isInactiveOwner
                        })
                    }
                }
            } catch { }
        }

        # Issues
        $issues = [System.Collections.Generic.List[string]]::new()
        if ($inactiveOwnerCount -gt 0)                                                              { $issues.Add('InactiveOwner')    }
        if ($disabledMembers.Count -gt 0)                                                           { $issues.Add('DisabledUser')     }
        if ($activeMembers.Count -eq 0 -and -not $isDynamic)                                       { $issues.Add('Empty')            }
        if ($ownerDetails.Count -eq 0 -and $ownerSource -eq 'graph' -and -not $isDynamic)          { $issues.Add('NoOwner')          }
        if ($nestedGroupNames.Count -gt 0)                                                          { $issues.Add('HasNested')        }
        if ($grp.onPremisesSyncEnabled -eq $true)                                                   { $issues.Add('OnPremSync')       }
        if ($guestMembers.Count -gt 0)                                                              { $issues.Add('HasGuests')        }

        $staleApplicable = $isUnified
        $isStale         = $false
        if ($isUnified) {
            if ($reportsAvailable) {
                if ($staleGroupIds.ContainsKey($grp.id)) { $issues.Add('Stale'); $isStale = $true }
            } elseif ($grp.renewedDateTime) {
                $age = ([datetime]::UtcNow - [datetime]$grp.renewedDateTime).TotalDays
                if ($age -gt $script:StaleDays) { $issues.Add('Stale'); $isStale = $true }
            }
        }

        $priority = if ($issues -contains 'DisabledUser' -or $issues -contains 'InactiveOwner') { 1 }
                    elseif ($issues -contains 'Empty')                                              { 2 }
                    elseif ($issues -contains 'NoOwner' -or $issues -contains 'Stale')             { 3 }
                    elseif ($issues.Count -gt 0)                                                   { 4 }
                    else                                                                            { 5 }

        $action = if ($issues.Count -eq 0)                                                          { 'No action needed'              }
                  elseif ($issues -contains 'DisabledUser' -or $issues -contains 'InactiveOwner')   { 'Review inactive users'         }
                  elseif ($issues -contains 'Empty')                                                { 'Review and delete if unused'   }
                  elseif ($issues -contains 'NoOwner')                                              { 'Assign an owner'               }
                  elseif ($issues -contains 'Stale')                                                { "No activity $script:StaleDays`d+ — review" }
                  elseif ($issues -contains 'HasNested')                                            { 'Review nested group access'    }
                  else                                                                              { 'Review flagged items'          }

        $results.Add([PSCustomObject]@{
            id               = $grp.id
            displayName      = $grp.displayName
            description      = $grp.description
            groupType        = $groupType
            groupCategory    = $groupCategory
            membershipType   = $membershipType
            isDynamic        = $isDynamic
            hasTeam          = $hasTeam
            membershipRule   = if ($isDynamic) { $grp.membershipRule } else { $null }
            mail             = $grp.mail
            createdDateTime  = $grp.createdDateTime
            onPremSync       = ($grp.onPremisesSyncEnabled -eq $true)

            totalMembers     = $memberDetails.Count
            activeMembers    = $activeMembers.Count
            inactiveOwnerCount = $inactiveOwnerCount
            disabledCount    = $disabledMembers.Count
            guestCount       = $guestMembers.Count
            members          = @($memberDetails | Sort-Object displayName)

            nestedGroupCount = $nestedGroupNames.Count
            nestedGroupNames = @($nestedGroupNames)

            owners           = @($ownerDetails)
            ownerCount       = $ownerDetails.Count
            ownerSource      = $ownerSource

            isStale          = $isStale
            staleApplicable  = $staleApplicable
            staleDays        = $script:StaleDays

            issues           = @($issues)
            priority         = $priority
            action           = $action
        })
    }

    Write-Progress -Activity "Loading groups" -Completed
    $script:GroupCache   = @($results)
    $script:LoadProgress = @{ status = 'done'; current = $idx; total = $idx; message = 'Ready' }
    Write-Log "Load complete — $idx groups processed" 'OK'
}

# ─── HTTP helpers ─────────────────────────────────────────────────────────────
function Send-Response {
    param($Res, [string]$Body, [string]$ContentType = 'text/html; charset=utf-8', [int]$Code = 200)
    try {
        $Res.StatusCode  = $Code
        $Res.ContentType = $ContentType
        # Security headers — defence-in-depth for a localhost-only app
        $Res.Headers.Add('X-Content-Type-Options',    'nosniff')
        $Res.Headers.Add('X-Frame-Options',           'DENY')
        $Res.Headers.Add('Referrer-Policy',           'no-referrer')
        $Res.Headers.Add('Content-Security-Policy',   "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:;")
        $Res.Headers.Add('Cache-Control',             'no-store')
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $Res.ContentLength64 = $bytes.Length
        $Res.OutputStream.Write($bytes, 0, $bytes.Length)
    } finally { $Res.OutputStream.Close() }
}

function Send-Json {
    param($Res, $Data, [int]$Code = 200)
    $json = $Data | ConvertTo-Json -Depth 10 -Compress
    Send-Response $Res $json 'application/json; charset=utf-8' $Code
}

function Send-Error {
    param($Res, [string]$Message, [int]$Code = 500)
    Send-Json $Res @{ error = $Message } $Code
}

function Assert-IsGuid {
    # Returns $true if the string is a valid GUID; used to reject path-injection attempts.
    param([string]$Value)
    return ($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
}

function Read-Body {
    param($Req)
    try {
        $reader = [System.IO.StreamReader]::new($Req.InputStream, [System.Text.Encoding]::UTF8)
        $text   = $reader.ReadToEnd()
        $reader.Close()
        if ($text) { return $text | ConvertFrom-Json } else { return $null }
    } catch { return $null }
}

function Get-RouteId {
    # Extract last path segment (e.g. /api/groups/abc123/members → abc123)
    param([string]$Path, [string]$Pattern)
    if ($Path -match $Pattern) { return $Matches[1] } else { return $null }
}

# ─── Write action handlers ────────────────────────────────────────────────────
function Add-GroupMember {
    param([string]$GroupId, [string]$UserId)
    $body = @{ '@odata.id' = "$script:BaseUrl/directoryObjects/$UserId" }
    Invoke-Graph "/groups/$GroupId/members/`$ref" -Method POST -Body $body | Out-Null
    $script:ActionLog.Insert(0, [PSCustomObject]@{
        timestamp = (Get-Date -Format 'o')
        action    = 'AddMember'
        groupId   = $GroupId
        targetId  = $UserId
        by        = $script:Me.displayName
    })
}

function Remove-GroupMember {
    param([string]$GroupId, [string]$UserId)
    Invoke-Graph "/groups/$GroupId/members/$UserId/`$ref" -Method DELETE | Out-Null
    $script:ActionLog.Insert(0, [PSCustomObject]@{
        timestamp = (Get-Date -Format 'o')
        action    = 'RemoveMember'
        groupId   = $GroupId
        targetId  = $UserId
        by        = $script:Me.displayName
    })
}

function Add-GroupOwner {
    param([string]$GroupId, [string]$UserId)
    $body = @{ '@odata.id' = "$script:BaseUrl/directoryObjects/$UserId" }
    Invoke-Graph "/groups/$GroupId/owners/`$ref" -Method POST -Body $body | Out-Null
    $script:ActionLog.Insert(0, [PSCustomObject]@{
        timestamp = (Get-Date -Format 'o')
        action    = 'AddOwner'
        groupId   = $GroupId
        targetId  = $UserId
        by        = $script:Me.displayName
    })
}

function Remove-GroupOwner {
    param([string]$GroupId, [string]$UserId)
    Invoke-Graph "/groups/$GroupId/owners/$UserId/`$ref" -Method DELETE | Out-Null
    $script:ActionLog.Insert(0, [PSCustomObject]@{
        timestamp = (Get-Date -Format 'o')
        action    = 'RemoveOwner'
        groupId   = $GroupId
        targetId  = $UserId
        by        = $script:Me.displayName
    })
}

# Update cached group after a write action
function Sync-CachedGroup {
    param([string]$GroupId)
    if (-not $script:GroupCache) { return }
    $idx = [array]::FindIndex($script:GroupCache, [Predicate[PSCustomObject]]{ param($g) $g.id -eq $GroupId })
    if ($idx -lt 0) { return }

    $grp = $script:GroupCache[$idx]

    # Reload members
    $userMap = $script:UserCache
    $memberDetails    = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $mProps  = 'id,displayName,userPrincipalName,accountEnabled,userType'
        $members = @(Invoke-Graph "/groups/$GroupId/members?`$select=$mProps&`$top=999" -All)
        foreach ($m in $members) {
            if ($userMap.ContainsKey($m.id)) {
                $u = $userMap[$m.id]
                $memberDetails.Add([PSCustomObject]@{
                    id=          $u.id;    displayName=$u.displayName; email=$u.email
                    department=  $u.department; companyName=$u.companyName; jobTitle=$u.jobTitle
                    officeLocation=$u.officeLocation
                    isDisabled=$u.isDisabled; isGuest=$u.isGuest; isActive=$u.isActive
                })
            }
        }
    } catch { }

    # Reload owners
    $ownerDetails = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($grp.ownerSource -eq 'graph') {
        try {
            $ownerObjs = @(Invoke-Graph "/groups/$GroupId/owners?`$select=id,displayName" -All)
            foreach ($o in $ownerObjs) {
                $oname = if ($o.PSObject.Properties['displayName']) { $o.displayName } else { '' }
                if ($oname) {
                    $ownerDetails.Add([PSCustomObject]@{
                        id            = $o.id
                        name          = $oname
                        isDisabled    = $userMap.ContainsKey($o.id) -and ($userMap[$o.id].isDisabled -eq $true)
                    })
                }
            }
        } catch { }
    }

    # Recompute issues
    $active         = @($memberDetails | Where-Object { $_.isActive })
    $disabled       = @($memberDetails | Where-Object { $_.isDisabled })
    $guests         = @($memberDetails | Where-Object { $_.isGuest })
    $inactiveOwnCount = @($ownerDetails | Where-Object { $_.isDisabled }).Count

    $issues = [System.Collections.Generic.List[string]]::new()
    if ($inactiveOwnCount -gt 0)                                                           { $issues.Add('InactiveOwner')    }
    if ($disabled.Count -gt 0)                                                             { $issues.Add('DisabledUser')     }
    if ($active.Count -eq 0 -and -not $grp.isDynamic)                                     { $issues.Add('Empty')            }
    if ($ownerDetails.Count -eq 0 -and $grp.ownerSource -eq 'graph' -and -not $grp.isDynamic) { $issues.Add('NoOwner')     }
    if ($grp.nestedGroupCount -gt 0)                                                       { $issues.Add('HasNested')       }
    if ($grp.onPremSync)                                                                   { $issues.Add('OnPremSync')      }
    if ($guests.Count -gt 0)                                                               { $issues.Add('HasGuests')       }
    if ($grp.isStale)                                                                      { $issues.Add('Stale')           }

    $priority = if ($issues -contains 'DisabledUser' -or $issues -contains 'InactiveOwner') { 1 }
                elseif ($issues -contains 'Empty')                                              { 2 }
                elseif ($issues -contains 'NoOwner' -or $issues -contains 'Stale')             { 3 }
                elseif ($issues.Count -gt 0)                                                   { 4 }
                else                                                                            { 5 }

    $action = if ($issues.Count -eq 0)                                                          { 'No action needed'            }
              elseif ($issues -contains 'DisabledUser' -or $issues -contains 'InactiveOwner')   { 'Review inactive users'       }
              elseif ($issues -contains 'Empty')                                                { 'Review and delete if unused' }
              elseif ($issues -contains 'NoOwner')                                              { 'Assign an owner'             }
              elseif ($issues -contains 'Stale')                                                { "No activity $script:StaleDays`d+ — review" }
              else                                                                              { 'Review flagged items'        }

    $grp.members          = @($memberDetails | Sort-Object displayName)
    $grp.totalMembers     = $memberDetails.Count
    $grp.activeMembers    = $active.Count
    $grp.inactiveOwnerCount = $inactiveOwnCount
    $grp.disabledCount    = $disabled.Count
    $grp.guestCount       = $guests.Count
    $grp.owners           = @($ownerDetails)
    $grp.ownerCount       = $ownerDetails.Count
    $grp.issues           = @($issues)
    $grp.priority         = $priority
    $grp.action           = $action
}

# ─── HTML app ─────────────────────────────────────────────────────────────────
$script:HtmlApp = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GroupDesk</title>
<style>
:root{
  --navy:#1a2744;--navy2:#243050;--blue:#2563eb;--purple:#7c3aed;
  --green:#16a34a;--red:#dc2626;--amber:#d97706;
  --bg:#f1f5f9;--surface:#fff;--border:#e2e8f0;--muted:#64748b;
  --text:#1e293b;--radius:8px;--shadow:0 1px 3px rgba(0,0,0,.08);
}
*{box-sizing:border-box;margin:0;padding:0;}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
  background:var(--bg);color:var(--text);font-size:14px;}

/* ── Header ── */
.header{background:var(--navy);color:#fff;padding:14px 24px;
  display:flex;align-items:center;justify-content:space-between;
  position:sticky;top:0;z-index:100;box-shadow:0 2px 8px rgba(0,0,0,.2);}
.header-title{font-size:16px;font-weight:700;letter-spacing:.3px;}
.header-meta{font-size:11px;opacity:.6;margin-top:2px;}
.header-right{display:flex;align-items:center;gap:12px;}
.user-chip{background:rgba(255,255,255,.12);border-radius:20px;
  padding:4px 12px;font-size:12px;}
.btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;
  border-radius:6px;border:none;font-size:12px;font-weight:600;
  cursor:pointer;transition:opacity .15s;}
.btn:hover{opacity:.85;}
.btn-primary{background:var(--blue);color:#fff;}
.btn-danger {background:var(--red);color:#fff;}
.btn-ghost {background:rgba(255,255,255,.15);color:#fff;}
.btn-sm{padding:3px 10px;font-size:11px;}
.btn-outline{background:#fff;border:1px solid var(--border);color:var(--text);}

/* ── Tabs ── */
.tabs{background:var(--navy2);display:flex;gap:2px;padding:0 24px;}
.tab{padding:10px 18px;color:rgba(255,255,255,.6);font-size:13px;
  font-weight:600;cursor:pointer;border-bottom:2px solid transparent;
  transition:color .15s;}
.tab.active{color:#fff;border-bottom-color:#fff;}

/* ── Auth screen ── */
.auth-screen{display:flex;flex-direction:column;align-items:center;
  justify-content:center;height:calc(100vh - 100px);gap:20px;text-align:center;}
.auth-screen h2{font-size:22px;color:var(--navy);}
.auth-screen p{color:var(--muted);max-width:380px;}
.ms-btn{display:inline-flex;align-items:center;gap:10px;padding:12px 24px;
  background:#fff;border:1px solid var(--border);border-radius:8px;
  font-size:15px;font-weight:600;color:var(--text);cursor:pointer;
  box-shadow:var(--shadow);transition:box-shadow .15s;}
.ms-btn:hover{box-shadow:0 4px 12px rgba(0,0,0,.12);}
.ms-logo{width:20px;height:20px;}

/* ── Loading screen ── */
.loading-screen{display:flex;flex-direction:column;align-items:center;
  justify-content:center;height:calc(100vh - 100px);gap:16px;text-align:center;}
.spinner{width:40px;height:40px;border:3px solid var(--border);
  border-top-color:var(--blue);border-radius:50%;animation:spin .8s linear infinite;}
@keyframes spin{to{transform:rotate(360deg)}}
.progress-bar-wrap{width:360px;background:var(--border);border-radius:4px;height:6px;margin-top:8px;}
.progress-bar{height:6px;border-radius:4px;background:var(--blue);
  transition:width .3s ease;width:0%;}
.progress-text{font-size:12px;color:var(--muted);}

/* ── Main content ── */
.main{padding:20px 24px;}

/* ── Cards ── */
.cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:20px;}
.card{background:var(--surface);border-radius:var(--radius);padding:16px 20px;
  flex:1;min-width:120px;box-shadow:var(--shadow);}
.card-num{font-size:26px;font-weight:800;line-height:1;}
.card-label{font-size:11px;color:var(--muted);margin-top:4px;}
.card-red   .card-num{color:var(--red);}
.card-amber .card-num{color:var(--amber);}
.card-green .card-num{color:var(--green);}

/* ── Filter bar ── */
.filter-bar{display:flex;align-items:center;gap:10px;flex-wrap:wrap;
  background:var(--surface);border-radius:var(--radius);padding:12px 16px;
  margin-bottom:16px;box-shadow:var(--shadow);}
.filter-bar label{font-size:11px;font-weight:700;color:var(--muted);text-transform:uppercase;}
.filter-bar input,.filter-bar select{
  border:1px solid var(--border);border-radius:6px;padding:5px 10px;
  font-size:13px;background:#fff;color:var(--text);}
.filter-bar input{width:200px;}
.filter-bar .spacer{flex:1;}

/* ── Table ── */
.tbl-wrap{background:var(--surface);border-radius:var(--radius);
  box-shadow:var(--shadow);overflow:hidden;}
table{width:100%;border-collapse:collapse;}
thead th{background:var(--navy);color:#fff;padding:10px 12px;
  font-size:11px;font-weight:700;text-align:left;
  cursor:pointer;user-select:none;white-space:nowrap;}
thead th:hover{background:var(--navy2);}
tbody tr.group-row{cursor:pointer;transition:background .1s;}
tbody tr.group-row:hover{background:#f8faff;}
tbody tr.group-row.expanded{background:#f0f4ff;}
tbody td{padding:10px 12px;border-bottom:1px solid var(--border);vertical-align:middle;}

/* ── Expand section ── */
tr.detail-section{display:none;}
tr.detail-section.open{display:table-row;}
tr.detail-section td{padding:0;background:#f8faff;border-bottom:2px solid var(--border);}
.detail-inner{padding:16px 20px 20px 36px;}
.detail-desc{font-size:12px;color:var(--muted);font-style:italic;margin-bottom:12px;}
.detail-desc strong{font-style:normal;font-weight:700;color:var(--navy);margin-right:6px;}
.detail-subtitle{font-size:12px;font-weight:700;color:var(--navy);margin-bottom:8px;}
.member-tbl{width:100%;border-collapse:collapse;font-size:12px;margin-bottom:12px;}
.member-tbl th{background:#eef1f8;padding:6px 10px;text-align:left;font-weight:700;
  font-size:11px;color:var(--muted);}
.member-tbl td{padding:6px 10px;border-bottom:1px solid var(--border);}
.member-tbl tr.former        td{background:#fff5f5;color:var(--red);}
.member-tbl tr.disabled-user td{background:#fff7ed;color:#92400e;}
.member-tbl tr.guest         td{color:var(--purple);}
.action-row{display:flex;gap:8px;margin-top:4px;}

/* ── Tags & flags ── */
.tag{display:inline-block;padding:2px 8px;border-radius:4px;
  font-size:10px;font-weight:700;letter-spacing:.4px;text-transform:uppercase;}
.tag-m365 {background:#dbeafe;color:#1d4ed8;}
.tag-sec  {background:#dcfce7;color:#15803d;}
.tag-dist {background:#fef9c3;color:#854d0e;}
.tag-unknown{background:#f1f5f9;color:var(--muted);}
.tag-assigned{background:#f1f5f9;color:var(--muted);}
.tag-dynamic{background:#f3e8ff;color:var(--purple);}

.flag{display:inline-flex;align-items:center;padding:2px 7px;border-radius:4px;
  font-size:10px;font-weight:700;margin:1px;white-space:nowrap;}
.flag-fs   {background:#fff1f2;color:var(--red);border:1px solid #fecdd3;}
.flag-emp  {background:#fff5f5;color:var(--red);}
.flag-noown{background:#fffbeb;color:var(--amber);}
.flag-stale{background:#fffbeb;color:var(--amber);}
.flag-na   {background:#f7f7f7;color:#aaa;font-style:italic;}
.flag-nest {background:#f3e8ff;color:var(--purple);}
.flag-sync {background:#f7f7f7;color:var(--muted);}
.flag-guest{background:#f0f9ff;color:#0369a1;}
.flag-dis  {background:#fff7ed;color:#c2410c;border:1px solid #fed7aa;}

.prio{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:4px;}
.prio-1{background:var(--red);}
.prio-2{background:var(--amber);}
.prio-3{background:var(--amber);opacity:.6;}
.prio-4{background:#94a3b8;}
.prio-5{background:#cbd5e1;}

.expand-icon{display:inline-block;margin-right:6px;font-size:10px;
  color:var(--muted);transition:transform .2s;}
.group-row.expanded .expand-icon{transform:rotate(90deg);}

.gname{font-weight:700;color:var(--navy);}
.gname-sep{color:var(--border);font-weight:400;margin:0 2px;}
.gname small{font-size:10px;font-weight:400;color:var(--muted);}
.teams-badge{display:inline-block;font-size:9px;font-weight:700;padding:1px 5px;
  border-radius:3px;background:#5b5fc7;color:#fff;margin-left:5px;vertical-align:middle;}
.member-badge{font-size:9px;padding:1px 4px;border-radius:3px;margin-left:4px;}
.badge-former  {background:#fecdd3;color:var(--red);}
.badge-disabled{background:#fed7aa;color:#c2410c;}
.badge-guest   {background:#dbeafe;color:#1d4ed8;}

/* ── Pager ── */
.pager{display:flex;align-items:center;justify-content:space-between;
  padding:10px 16px;font-size:12px;color:var(--muted);}
.pager-btns{display:flex;gap:6px;}
.pager-btns button{padding:4px 10px;border:1px solid var(--border);border-radius:5px;
  background:#fff;cursor:pointer;font-size:12px;}
.pager-btns button:disabled{opacity:.4;cursor:default;}

/* ── Modal ── */
.modal-overlay{position:fixed;inset:0;background:rgba(0,0,0,.45);
  display:flex;align-items:center;justify-content:center;z-index:200;display:none;}
.modal-overlay.open{display:flex;}
.modal{background:#fff;border-radius:12px;padding:28px;width:440px;
  box-shadow:0 20px 60px rgba(0,0,0,.25);}
.modal h3{font-size:16px;font-weight:700;margin-bottom:8px;}
.modal p{color:var(--muted);font-size:13px;line-height:1.5;margin-bottom:20px;}
.modal-btns{display:flex;justify-content:flex-end;gap:10px;}

/* ── Action log ── */
.log-wrap{background:var(--surface);border-radius:var(--radius);
  box-shadow:var(--shadow);overflow:hidden;}
.log-empty{padding:40px;text-align:center;color:var(--muted);font-size:13px;}
.log-row{display:flex;gap:12px;padding:10px 16px;border-bottom:1px solid var(--border);
  font-size:12px;align-items:flex-start;}
.log-row:last-child{border-bottom:none;}
.log-action{font-weight:700;min-width:120px;}
.log-action.add{color:var(--green);}
.log-action.remove{color:var(--red);}
.log-meta{color:var(--muted);}

/* ── User search dropdown ── */
.user-search-wrap{position:relative;}
.user-search-wrap input{width:100%;border:1px solid var(--border);border-radius:6px;
  padding:8px 12px;font-size:13px;}
.user-dropdown{position:absolute;top:100%;left:0;right:0;background:#fff;
  border:1px solid var(--border);border-radius:6px;box-shadow:var(--shadow);
  max-height:200px;overflow-y:auto;z-index:10;display:none;}
.user-dropdown.open{display:block;}
.user-opt{padding:8px 12px;cursor:pointer;font-size:13px;}
.user-opt:hover{background:#f8faff;}
.user-opt small{color:var(--muted);display:block;font-size:11px;}

/* ── Users tab ── */
.usr-tbl td{padding:8px 12px;border-bottom:1px solid var(--border);vertical-align:middle;}
</style>
</head>
<body>

<!-- Header -->
<div class="header">
  <div>
    <div class="header-title">GroupDesk</div>
    <div class="header-meta" id="headerMeta">Connecting...</div>
  </div>
  <div class="header-right" id="headerRight" style="display:none;">
    <span class="user-chip" id="userChip"></span>
    <button class="btn btn-ghost" onclick="refreshData()">↺ Refresh</button>
    <button class="btn btn-ghost" onclick="signOut()" style="background:rgba(220,38,38,.3);">Sign Out</button>
  </div>
</div>

<!-- Tabs -->
<div class="tabs" id="tabs" style="display:none;">
  <div class="tab active" onclick="showTab('groups',this)">Groups</div>
  <div class="tab" onclick="showTab('users',this)">Users</div>
  <div class="tab" onclick="showTab('log',this)">Action Log <span id="logBadge"></span></div>
</div>

<!-- Auth screen -->
<div class="auth-screen" id="authScreen" style="display:none;">
  <svg class="ms-logo" style="width:48px;height:48px;" viewBox="0 0 21 21" fill="none">
    <rect x="1" y="1" width="9" height="9" fill="#f25022"/>
    <rect x="11" y="1" width="9" height="9" fill="#7fba00"/>
    <rect x="1" y="11" width="9" height="9" fill="#00a4ef"/>
    <rect x="11" y="11" width="9" height="9" fill="#ffb900"/>
  </svg>
  <h2>GroupDesk</h2>
  <p>Sign in with your Microsoft account to access the console. Only authorised IT team members can proceed.</p>
  <button class="ms-btn" onclick="signIn()">
    <svg class="ms-logo" viewBox="0 0 21 21" fill="none">
      <rect x="1" y="1" width="9" height="9" fill="#f25022"/>
      <rect x="11" y="1" width="9" height="9" fill="#7fba00"/>
      <rect x="1" y="11" width="9" height="9" fill="#00a4ef"/>
      <rect x="11" y="11" width="9" height="9" fill="#ffb900"/>
    </svg>
    Sign in with Microsoft
  </button>
</div>

<!-- Loading screen -->
<div class="loading-screen" id="loadingScreen" style="display:none;">
  <div class="spinner"></div>
  <div style="font-weight:700;font-size:15px;">Loading group data...</div>
  <div class="progress-bar-wrap"><div class="progress-bar" id="progressBar"></div></div>
  <div class="progress-text" id="progressText">Starting...</div>
  <div style="font-size:11px;color:var(--muted);margin-top:4px;">
    Progress is visible in the PowerShell console
  </div>
</div>

<!-- Groups tab -->
<div class="main" id="tabGroups" style="display:none;">
  <div class="cards" id="grpCards"></div>
  <div class="filter-bar">
    <label>SEARCH</label>
    <input type="text" id="grpSearch" placeholder="Group name or description..." oninput="grpFilter()">
    <label>TYPE</label>
    <select id="grpType" onchange="grpFilter()">
      <option value="">All types</option>
      <option value="Microsoft 365">Microsoft 365</option>
      <option value="Security">Security</option>
      <option value="Distribution">Distribution</option>
      <option value="Teams">Teams</option>
    </select>
    <label>MEMBERSHIP</label>
    <select id="grpMembership" onchange="grpFilter()">
      <option value="">All</option>
      <option value="Assigned">Assigned</option>
      <option value="Dynamic">Dynamic</option>
    </select>
    <label>ISSUE</label>
    <select id="grpIssue" onchange="grpFilter()">
      <option value="">All groups</option>
      <option value="DisabledUser">Inactive Member</option>
      <option value="InactiveOwner">Inactive Owner</option>
      <option value="Empty">Empty</option>
      <option value="NoOwner">No Owner</option>
      <option value="Stale">Stale</option>
      <option value="HasNested">Has Nested Groups</option>
      <option value="OnPremSync">On-Prem Sync</option>
      <option value="none">No Issues</option>
    </select>
    <button class="btn btn-outline" onclick="clearGrpFilter()">Clear</button>
    <button class="btn btn-outline" onclick="exportCSV()">Export CSV</button>
    <div class="spacer"></div>
    <span id="grpCount" style="font-size:12px;font-weight:600;color:var(--muted);white-space:nowrap;"></span>
  </div>
  <div class="tbl-wrap">
    <table>
      <thead>
        <tr>
          <th style="width:30px;"></th>
          <th onclick="grpSort('displayName')">Group Name ↕</th>
          <th onclick="grpSort('groupCategory')">Type ↕</th>
          <th onclick="grpSort('membershipType')">Membership ↕</th>
          <th onclick="grpSort('activeMembers')">Members ↕</th>
          <th>Nested Groups</th>
          <th>Dynamic Rule</th>
          <th>Owners</th>
          <th>Issues</th>
          <th onclick="grpSort('action')">Recommended Action ↕</th>
        </tr>
      </thead>
      <tbody id="grpBody"></tbody>
    </table>
    <div class="pager" id="grpPager"></div>
  </div>
</div>

<!-- Users tab -->
<div class="main" id="tabUsers" style="display:none;">
  <div class="cards" id="usrCards"></div>
  <div class="filter-bar">
    <label>SEARCH</label>
    <input type="text" id="usrSearch" placeholder="Name, email, or department..." oninput="uPage=1;renderUsersTab()">
    <label>STATUS</label>
    <select id="usrType" onchange="uPage=1;renderUsersTab()">
      <option value="">All users</option>
      <option value="active">Active</option>
      <option value="inactive">Inactive</option>
      <option value="guest">Guest</option>
    </select>
    <label>MIN GROUPS</label>
    <select id="usrMinGroups" onchange="uPage=1;renderUsersTab()">
      <option value="0">Any</option>
      <option value="1">1+</option>
      <option value="5">5+</option>
      <option value="10">10+</option>
      <option value="20">20+</option>
    </select>
    <button class="btn btn-outline" onclick="clearUsrFilter()">Clear</button>
    <div class="spacer"></div>
    <span id="usrCount" style="font-size:12px;font-weight:600;color:var(--muted);white-space:nowrap;"></span>
  </div>
  <div class="tbl-wrap">
    <table>
      <thead>
        <tr>
          <th style="width:30px;"></th>
          <th onclick="usrSort('displayName')">Name ↕</th>
          <th onclick="usrSort('email')">Email ↕</th>
          <th onclick="usrSort('department')">Department ↕</th>
          <th onclick="usrSort('companyName')">Company ↕</th>
          <th onclick="usrSort('jobTitle')">Job Title ↕</th>
          <th onclick="usrSort('officeLocation')">Office ↕</th>
          <th onclick="usrSort('_groups')">Groups ↕</th>
        </tr>
      </thead>
      <tbody id="usrBody"></tbody>
    </table>
    <div class="pager" id="usrPager"></div>
  </div>
</div>

<!-- Action log tab -->
<div class="main" id="tabLog" style="display:none;">
  <div class="log-wrap" id="logWrap">
    <div class="log-empty">No actions taken yet this session.</div>
  </div>
</div>

<!-- Confirmation modal -->
<div class="modal-overlay" id="modalOverlay">
  <div class="modal">
    <h3 id="modalTitle">Confirm action</h3>
    <p id="modalBody"></p>
    <div class="modal-btns">
      <button class="btn btn-outline" onclick="closeModal()">Cancel</button>
      <button class="btn btn-danger" id="modalConfirm" onclick="confirmAction()">Confirm</button>
    </div>
  </div>
</div>

<!-- Add member/owner modal -->
<div class="modal-overlay" id="addModalOverlay">
  <div class="modal">
    <h3 id="addModalTitle">Add member</h3>
    <p style="margin-bottom:12px;color:var(--muted);font-size:13px;" id="addModalDesc"></p>
    <div class="user-search-wrap">
      <input type="text" id="userSearchInput" placeholder="Search by name or email..."
             oninput="searchUsers(this.value)" autocomplete="off">
      <div class="user-dropdown" id="userDropdown"></div>
    </div>
    <div style="margin-top:16px;padding:10px;background:#f8faff;border-radius:6px;
                font-size:13px;display:none;" id="selectedUserChip"></div>
    <div class="modal-btns" style="margin-top:20px;">
      <button class="btn btn-outline" onclick="closeAddModal()">Cancel</button>
      <button class="btn btn-primary" id="addModalConfirm" onclick="confirmAdd()" disabled>Add</button>
    </div>
  </div>
</div>

<script>
// ── State ──────────────────────────────────────────────────────────────────
let GROUPS = [], gFiltered = [], USERS = [];
let USER_GROUP_MAP = {};
let gPage = 1, G_PAGE = 50;
let uPage = 1, U_PAGE = 50, uFiltered = [];
let uSortKey = 'displayName', uSortAsc = true;
let gSortKey = 'priority', gSortAsc = true;
let pendingAction = null;
let addContext = null;  // { groupId, type: 'member'|'owner' }
let selectedUser = null;
let searchTimer = null;
let _dropdownUsers = [];  // parallel array for user dropdown — avoids JSON in onclick

const CAT_CSS = {
  'Microsoft 365': 'tag-m365',
  'Security':      'tag-sec',
  'Distribution':  'tag-dist',
};
const MEM_CSS = { 'Assigned': 'tag-assigned', 'Dynamic': 'tag-dynamic' };

// ── Utility ────────────────────────────────────────────────────────────────
function esc(s) {
  if (s == null) return '';
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;').replace(/\\/g,'&#92;');
}
async function api(path, opts={}) {
  const r = await fetch(path, { headers:{'Content-Type':'application/json'}, ...opts });
  if (!r.ok) { const e = await r.json().catch(()=>({})); throw new Error(e.error||`HTTP ${r.status}`); }
  return r.json();
}
function showTab(name, el) {
  document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));
  el.classList.add('active');
  document.getElementById('tabGroups').style.display = name==='groups'?'block':'none';
  document.getElementById('tabUsers').style.display  = name==='users' ?'block':'none';
  document.getElementById('tabLog').style.display    = name==='log'   ?'block':'none';
  if (name==='log')   renderLog();
  if (name==='users') renderUsersTab();
}

// ── Bootstrap ──────────────────────────────────────────────────────────────
async function init() {
  try {
    const auth = await api('/api/auth');
    if (!auth.authenticated) {
      document.getElementById('authScreen').style.display = 'flex';
      document.getElementById('headerMeta').textContent = 'Not signed in';
      window._authUrl = auth.authUrl;
    } else {
      document.getElementById('headerRight').style.display = 'flex';
      document.getElementById('userChip').textContent = auth.user.displayName;
      document.getElementById('tabs').style.display = 'flex';
      document.getElementById('headerMeta').textContent =
        `${auth.user.mail} · ${new Date().toLocaleString()}`;
      await loadGroups();
    }
  } catch(e) {
    document.getElementById('headerMeta').textContent = 'Error: ' + e.message;
  }
}

function signIn() {
  if (window._authUrl) window.location.href = window._authUrl;
}

async function loadGroups() {
  document.getElementById('loadingScreen').style.display = 'flex';
  document.getElementById('tabGroups').style.display = 'none';
  document.getElementById('tabs').style.display = 'none';

  // Poll progress while waiting for /api/groups
  const pollInterval = setInterval(async () => {
    try {
      const p = await api('/api/progress');
      document.getElementById('progressText').textContent = p.message || '';
      if (p.total > 0) {
        const pct = Math.round((p.current / p.total) * 100);
        document.getElementById('progressBar').style.width = pct + '%';
      }
    } catch(_) {}
  }, 2000);

  try {
    const data = await api('/api/groups');
    clearInterval(pollInterval);
    GROUPS = data;
    USERS  = await api('/api/users');
    USER_GROUP_MAP = buildUserGroupMap();
    grpFilter();
    renderCards();
    document.getElementById('loadingScreen').style.display = 'none';
    document.getElementById('tabGroups').style.display = 'block';
    document.getElementById('tabs').style.display = 'flex';
  } catch(e) {
    clearInterval(pollInterval);
    document.getElementById('progressText').textContent = 'Error: ' + e.message;
  }
}

async function refreshData() {
  try { await api('/api/refresh', { method:'POST' }); } catch(_){}
  await loadGroups();
}

// ── Cards ──────────────────────────────────────────────────────────────────
function renderCards() {
  const fs = GROUPS.filter(g=>g.issues.includes('DisabledUser')).length;
  const em = GROUPS.filter(g=>g.issues.includes('Empty')).length;
  const no = GROUPS.filter(g=>g.issues.includes('NoOwner')).length;
  const st = GROUPS.filter(g=>g.issues.includes('Stale')).length;
  const ok = GROUPS.filter(g=>g.issues.length===0).length;
  document.getElementById('grpCards').innerHTML = [
    `<div class="card card-${GROUPS.length>0?'':'green'}">
       <div class="card-num">${GROUPS.length}</div><div class="card-label">Groups Audited</div></div>`,
    `<div class="card ${fs>0?'card-red':''}">
       <div class="card-num">${fs}</div><div class="card-label">Have Inactive Members</div></div>`,
    `<div class="card ${em>0?'card-amber':''}">
       <div class="card-num">${em}</div><div class="card-label">Empty Groups</div></div>`,
    `<div class="card ${no>0?'card-amber':''}">
       <div class="card-num">${no}</div><div class="card-label">No Owner (M365)</div></div>`,
    `<div class="card ${st>0?'card-amber':''}">
       <div class="card-num">${st}</div><div class="card-label">Stale 90d+</div></div>`,
    `<div class="card card-green">
       <div class="card-num">${ok}</div><div class="card-label">No Issues</div></div>`,
  ].join('');
}

// ── Filter & Sort ──────────────────────────────────────────────────────────
function grpFilter() {
  const s   = document.getElementById('grpSearch').value.toLowerCase();
  const t   = document.getElementById('grpType').value;
  const mem = document.getElementById('grpMembership').value;
  const iss = document.getElementById('grpIssue').value;
  gFiltered = GROUPS.filter(g => {
    if (s && !g.displayName.toLowerCase().includes(s) &&
             !(g.description||'').toLowerCase().includes(s)) return false;
    if (t === 'Teams') { if (!g.hasTeam) return false; }
    else if (t && g.groupCategory !== t) return false;
    if (mem && g.membershipType !== mem) return false;
    if (iss === 'none' && g.issues.length > 0) return false;
    if (iss && iss !== 'none' && !g.issues.includes(iss)) return false;
    return true;
  });
  grpSortApply();
  gPage = 1;
  renderGrpTable();
}

function grpSort(key) {
  if (gSortKey === key) { gSortAsc = !gSortAsc; } else { gSortKey = key; gSortAsc = true; }
  grpSortApply();
  gPage = 1;
  renderGrpTable();
}

function grpSortApply() {
  gFiltered.sort((a,b) => {
    let av = a[gSortKey] ?? '', bv = b[gSortKey] ?? '';
    if (typeof av === 'number') return gSortAsc ? av-bv : bv-av;
    return gSortAsc ? String(av).localeCompare(String(bv)) : String(bv).localeCompare(String(av));
  });
}

function clearGrpFilter() {
  document.getElementById('grpSearch').value = '';
  document.getElementById('grpType').value = '';
  document.getElementById('grpMembership').value = '';
  document.getElementById('grpIssue').value = '';
  grpFilter();
}

// ── Render table ───────────────────────────────────────────────────────────
function renderGrpTable() {
  const start = (gPage-1)*G_PAGE, end = start+G_PAGE;
  const page  = gFiltered.slice(start, end);
  const rows  = page.map((g,i) => {
    const idx = start + i;
    const rid = `dr-${idx}`;

    const memberCell = g.isDynamic
      ? '<span style="color:var(--purple);font-size:11px;">Dynamic</span>'
      : `${g.activeMembers} active${g.disabledCount>0?` · <span style="color:#c2410c;">${g.disabledCount} inactive</span>`:''}`;

    const nestedCell = g.nestedGroupCount > 0
      ? `<strong>${g.nestedGroupCount}</strong>`
      : '—';

    const dynRule = g.membershipRule
      ? `<span title="${esc(g.membershipRule)}" style="font-size:10px;color:var(--purple);cursor:help;">View rule</span>`
      : '—';

    const ownersCell = g.ownerSource === 'exchange'
      ? '<span style="color:var(--muted);font-size:10px;font-style:italic;" title="Managed via Exchange Online (ManagedBy)">Exchange managed</span>'
      : g.owners.length > 0
        ? g.owners.map(o =>
            `<div style="font-size:11px;${o.isFormerStaff?'color:var(--red);font-weight:600;':o.isDisabled?'color:#c2410c;font-weight:600;':''}">
               ${esc(o.name)}${o.isFormerStaff?' <span class="member-badge badge-former">FORMER</span>':o.isDisabled?' <span class="member-badge badge-disabled">INACTIVE</span>':''}
             </div>`).join('')
        : '<span style="color:var(--amber);font-size:11px;font-weight:600;">None</span>';

    const flags = flagsHtml(g);

    return `
      <tr class="group-row" onclick="toggleDetail('${rid}',this,'${esc(g.id)}')">
        <td style="text-align:center;">
          <span class="expand-icon">▶</span>
          <span class="prio prio-${g.priority}"></span>
        </td>
        <td>
          <div class="gname">
            ${esc(g.displayName)}
            ${g.hasTeam?'<span class="teams-badge" title="Connected to Teams">Teams</span>':''}
            ${g.mail?`<span class="gname-sep"> · </span><small>${esc(g.mail)}</small>`:''}
          </div>
        </td>
        <td><span class="tag ${CAT_CSS[g.groupCategory]||'tag-unknown'}">${esc(g.groupCategory)}</span></td>
        <td><span class="tag ${MEM_CSS[g.membershipType]||'tag-unknown'}">${esc(g.membershipType)}</span></td>
        <td>${memberCell}</td>
        <td>${nestedCell}</td>
        <td>${dynRule}</td>
        <td>${ownersCell}</td>
        <td>${flags}</td>
        <td style="font-size:11px;">${esc(g.action)}</td>
      </tr>
      <tr class="detail-section" id="${rid}">
        <td colspan="10">
          <div class="detail-inner" id="di-${idx}"></div>
        </td>
      </tr>`;
  });

  document.getElementById('grpBody').innerHTML = rows.join('');
  renderGrpPager();
}

function flagsHtml(g) {
  const out = [];
  if (g.issues.includes('DisabledUser'))     out.push(`<span class="flag flag-dis">⚠ Inactive (${g.disabledCount})</span>`);
  if (g.issues.includes('InactiveOwner'))    out.push(`<span class="flag flag-dis">⚠ Inactive Owner</span>`);
  if (g.issues.includes('Empty'))            out.push(`<span class="flag flag-emp">Empty</span>`);
  if (g.issues.includes('NoOwner'))          out.push(`<span class="flag flag-noown">No Owner</span>`);
  if (g.issues.includes('Stale'))            out.push(`<span class="flag flag-stale">Stale ${g.staleDays}d+</span>`);
  else if (!g.staleApplicable)               out.push(`<span class="flag flag-na" title="Stale detection only applies to M365 groups">Stale N/A</span>`);
  if (g.issues.includes('HasNested'))        out.push(`<span class="flag flag-nest">Nested</span>`);
  if (g.issues.includes('OnPremSync'))       out.push(`<span class="flag flag-sync">On-Prem</span>`);
  if (g.issues.includes('HasGuests'))        out.push(`<span class="flag flag-guest">Guests (${g.guestCount})</span>`);
  return out.join('') || '<span style="color:var(--muted);font-size:11px;">—</span>';
}

// ── Pager ──────────────────────────────────────────────────────────────────
function renderGrpPager() {
  const total = gFiltered.length;
  const pages = Math.ceil(total / G_PAGE);
  document.getElementById('grpCount').textContent = `${total} group${total===1?'':'s'}`;
  document.getElementById('grpPager').innerHTML = `
    <div class="pager-btns">
      <button onclick="goPage(${gPage-1})" ${gPage<=1?'disabled':''}>← Prev</button>
      <span style="padding:4px 8px;">Page ${gPage} / ${pages||1}</span>
      <button onclick="goPage(${gPage+1})" ${gPage>=pages?'disabled':''}>Next →</button>
    </div>`;
}
function goPage(p) { gPage = p; renderGrpTable(); }

// ── Detail expand ──────────────────────────────────────────────────────────
function toggleDetail(rid, row, groupId) {
  const sec  = document.getElementById(rid);
  const open = sec.classList.toggle('open');
  row.classList.toggle('expanded', open);
  if (open) {
    const idx  = rid.replace('dr-','');
    const g    = gFiltered[parseInt(idx)];
    if (g) renderDetailInner(idx, g);
  }
}

function renderDetailInner(idx, g) {
  const container = document.getElementById(`di-${idx}`);
  const desc = g.description
    ? `<div class="detail-desc"><strong>Description</strong>${esc(g.description)}</div>` : '';

  const memberRows = g.members.map(m => {
    const cls = m.isDisabled?'disabled-user':m.isGuest?'guest':'';
    return `<tr class="${cls}">
      <td>${esc(m.displayName)}
        ${m.isDisabled?'<span class="member-badge badge-disabled">INACTIVE</span>':''}
        ${m.isGuest?'<span class="member-badge" style="background:#dbeafe;color:#1d4ed8;">GUEST</span>':''}
      </td>
      <td>${esc(m.email)}</td>
      <td>${esc(m.department)||'—'}</td>
      <td>${esc(m.jobTitle)||'—'}</td>
      <td>${esc(m.companyName)||'—'}</td>
      <td>
        ${!g.isDynamic?`<button class="btn btn-danger btn-sm" onclick="promptRemoveMember('${esc(g.id)}','${esc(m.id)}','${esc(m.displayName)}','${esc(g.displayName)}',event)">Remove</button>`:''}
      </td>
    </tr>`;
  }).join('');

  const ownerRows = g.ownerSource === 'exchange' ? '' :
    g.owners.map(o => `<tr class="${o.isFormerStaff?'former':o.isDisabled?'disabled-user':''}">
      <td>${esc(o.name)}${o.isFormerStaff?'<span class="member-badge badge-former">FORMER</span>':o.isDisabled?'<span class="member-badge badge-disabled">INACTIVE</span>':''}</td>
      <td><button class="btn btn-danger btn-sm" onclick="promptRemoveOwner('${esc(g.id)}','${esc(o.id)}','${esc(o.name)}','${esc(g.displayName)}',event)">Remove</button></td>
    </tr>`).join('');

  const ownersSection = g.ownerSource === 'exchange'
    ? '<div style="font-size:12px;color:var(--muted);font-style:italic;margin-bottom:8px;">Managed via Exchange Online (ManagedBy).</div>'
    : g.owners.length > 0
      ? `<table class="member-tbl"><thead><tr><th>Name</th><th></th></tr></thead><tbody>${ownerRows}</tbody></table>`
      : '<div style="font-size:12px;color:var(--amber);font-weight:600;margin-bottom:8px;">No owners assigned</div>';

  const nestedHtml = g.nestedGroupNames.length > 0
    ? `<div class="detail-subtitle" style="margin-top:12px;">Nested Groups</div>
       <ul style="font-size:12px;margin-left:16px;color:var(--purple);">
         ${g.nestedGroupNames.map(n=>`<li>${esc(n)}</li>`).join('')}
       </ul>` : '';

  const dynRuleHtml = g.membershipRule
    ? `<div class="detail-subtitle" style="margin-top:12px;">Dynamic Rule</div>
       <code style="font-size:11px;background:#f1f5f9;padding:6px 10px;border-radius:4px;
                    display:block;margin-top:4px;white-space:pre-wrap;word-break:break-all;">${esc(g.membershipRule)}</code>` : '';

  const addMemberBtn = !g.isDynamic
    ? `<button class="btn btn-primary btn-sm" style="margin-top:8px;" onclick="promptAdd('${esc(g.id)}','member','${esc(g.displayName)}',event)">+ Add Member</button>` : '';
  const addOwnerBtn = !g.isDynamic && g.ownerSource==='graph'
    ? `<button class="btn btn-outline btn-sm" style="margin-top:4px;" onclick="promptAdd('${esc(g.id)}','owner','${esc(g.displayName)}',event)">+ Add Owner</button>` : '';

  container.innerHTML = `
    <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-bottom:16px;font-size:12px;">
      <div><span style="color:var(--muted);text-transform:uppercase;font-size:10px;font-weight:700;">Type</span><br>${esc(g.groupCategory)} · ${esc(g.membershipType)}</div>
      <div><span style="color:var(--muted);text-transform:uppercase;font-size:10px;font-weight:700;">Email</span><br>${esc(g.mail)||'—'}</div>
      <div><span style="color:var(--muted);text-transform:uppercase;font-size:10px;font-weight:700;">Description</span><br>${esc(g.description)||'—'}</div>
    </div>
    <div style="display:grid;grid-template-columns:1fr 2fr;gap:24px;">
      <div>
        <div class="detail-subtitle">Owners (${g.ownerCount})</div>
        ${ownersSection}
        ${nestedHtml}
        ${dynRuleHtml}
        ${addOwnerBtn}
      </div>
      <div>
        <div class="detail-subtitle">Members (${g.totalMembers})</div>
        ${g.members.length > 0 ? `
          <table class="member-tbl">
            <thead><tr>
              <th>Name</th><th>Email</th><th>Department</th><th>Job Title</th><th>Company</th><th></th>
            </tr></thead>
            <tbody>${memberRows}</tbody>
          </table>` : '<div style="font-size:12px;color:var(--muted);margin-bottom:8px;">No members</div>'}
        ${addMemberBtn}
      </div>
    </div>`;
}

// ── Write actions ──────────────────────────────────────────────────────────
function promptRemoveMember(groupId, userId, userName, groupName, e) {
  e.stopPropagation();
  pendingAction = async () => {
    await api(`/api/groups/${groupId}/members/${userId}`, { method:'DELETE' });
    await refreshGroup(groupId);
    updateLogBadge();
  };
  document.getElementById('modalTitle').textContent = 'Remove member';
  document.getElementById('modalBody').textContent  =
    `Remove "${userName}" from "${groupName}"? This cannot be undone from this console.`;
  document.getElementById('modalConfirm').textContent = 'Remove';
  document.getElementById('modalOverlay').classList.add('open');
}

function promptRemoveOwner(groupId, userId, userName, groupName, e) {
  e.stopPropagation();
  pendingAction = async () => {
    await api(`/api/groups/${groupId}/owners/${userId}`, { method:'DELETE' });
    await refreshGroup(groupId);
    updateLogBadge();
  };
  document.getElementById('modalTitle').textContent = 'Remove owner';
  document.getElementById('modalBody').textContent  =
    `Remove "${userName}" as owner of "${groupName}"?`;
  document.getElementById('modalConfirm').textContent = 'Remove';
  document.getElementById('modalOverlay').classList.add('open');
}

function promptAdd(groupId, type, groupName, e) {
  e.stopPropagation();
  addContext = { groupId, type };
  selectedUser = null;
  document.getElementById('addModalTitle').textContent = type === 'member' ? 'Add member' : 'Add owner';
  document.getElementById('addModalDesc').textContent  = `Search for a user to add to "${groupName}"`;
  document.getElementById('userSearchInput').value = '';
  document.getElementById('userDropdown').classList.remove('open');
  document.getElementById('selectedUserChip').style.display = 'none';
  document.getElementById('addModalConfirm').disabled = true;
  document.getElementById('addModalOverlay').classList.add('open');
}

function closeModal()    { document.getElementById('modalOverlay').classList.remove('open'); pendingAction = null; }
function closeAddModal() { document.getElementById('addModalOverlay').classList.remove('open'); addContext = null; selectedUser = null; }

async function confirmAction() {
  if (!pendingAction) return;
  const btn = document.getElementById('modalConfirm');
  btn.disabled = true; btn.textContent = 'Working...';
  try { await pendingAction(); } catch(e) { alert('Error: ' + e.message); }
  btn.disabled = false; btn.textContent = 'Confirm';
  closeModal();
}

async function confirmAdd() {
  if (!selectedUser || !addContext) return;
  const btn = document.getElementById('addModalConfirm');
  btn.disabled = true; btn.textContent = 'Adding...';
  try {
    const path = addContext.type === 'member'
      ? `/api/groups/${addContext.groupId}/members`
      : `/api/groups/${addContext.groupId}/owners`;
    await api(path, { method:'POST', body: JSON.stringify({ userId: selectedUser.id }) });
    await refreshGroup(addContext.groupId);
    updateLogBadge();
    closeAddModal();
  } catch(e) { alert('Error: ' + e.message); }
  btn.disabled = false; btn.textContent = 'Add';
}

// ── User search ────────────────────────────────────────────────────────────
function searchUsers(q) {
  clearTimeout(searchTimer);
  if (!q || q.length < 2) { document.getElementById('userDropdown').classList.remove('open'); return; }
  searchTimer = setTimeout(async () => {
    const results = USERS.filter(u =>
      u.displayName.toLowerCase().includes(q.toLowerCase()) ||
      (u.email||'').toLowerCase().includes(q.toLowerCase())
    ).slice(0, 10);
    _dropdownUsers = results;  // store refs — avoids serialising user objects into onclick
    const dd = document.getElementById('userDropdown');
    dd.innerHTML = results.map((u, i) =>
      `<div class="user-opt" data-idx="${i}">
         ${esc(u.displayName)}<small>${esc(u.email)}</small>
       </div>`).join('') || '<div class="user-opt" style="color:var(--muted);">No results</div>';
    dd.classList.add('open');
  }, 300);
}

function selectUser(u) {
  selectedUser = u;
  document.getElementById('userSearchInput').value = u.displayName;
  document.getElementById('userDropdown').classList.remove('open');
  const chip = document.getElementById('selectedUserChip');
  chip.style.display = 'block';
  chip.innerHTML = `<strong>${esc(u.displayName)}</strong> <span style="color:var(--muted)">${esc(u.email)}</span>`;
  document.getElementById('addModalConfirm').disabled = false;
}

// ── Refresh single group ───────────────────────────────────────────────────
async function refreshGroup(groupId) {
  try {
    const updated = await api(`/api/groups/${groupId}`);
    const i = GROUPS.findIndex(g => g.id === groupId);
    if (i >= 0) GROUPS[i] = updated;
    const fi = gFiltered.findIndex(g => g.id === groupId);
    if (fi >= 0) { gFiltered[fi] = updated; renderDetailInner(fi, updated); }
    USER_GROUP_MAP = buildUserGroupMap();
    renderCards();
  } catch(e) { console.error(e); }
}

// ── Action log ─────────────────────────────────────────────────────────────
async function renderLog() {
  const log = await api('/api/log').catch(()=>[]);
  const wrap = document.getElementById('logWrap');
  if (!log.length) {
    wrap.innerHTML = '<div class="log-empty">No actions taken yet this session.</div>';
    return;
  }
  const actionLabels = {
    AddMember: 'Added Member', RemoveMember: 'Removed Member',
    AddOwner:  'Added Owner',  RemoveOwner:  'Removed Owner'
  };
  const actionCls = { AddMember:'add', AddOwner:'add', RemoveMember:'remove', RemoveOwner:'remove' };
  wrap.innerHTML = log.map(e => {
    const g = GROUPS.find(g => g.id === e.groupId);
    const u = USERS.find(u => u.id === e.targetId);
    return `<div class="log-row">
      <span class="log-action ${actionCls[e.action]||''}">${actionLabels[e.action]||e.action}</span>
      <div>
        <div><strong>${esc(u?.displayName||e.targetId)}</strong> — ${esc(g?.displayName||e.groupId)}</div>
        <div class="log-meta">${new Date(e.timestamp).toLocaleString()} · by ${esc(e.by)}</div>
      </div>
    </div>`;
  }).join('');
}

function updateLogBadge() {
  api('/api/log').then(log => {
    document.getElementById('logBadge').textContent = log.length ? `(${log.length})` : '';
  }).catch(()=>{});
}

// ── CSV export ─────────────────────────────────────────────────────────────
function exportCSV() {
  const cols = ['displayName','mail','groupCategory','membershipType',
                'activeMembers','formerStaffCount','guestCount','nestedGroupCount',
                'ownerCount','isStale','membershipRule','action'];
  const rows = [cols.join(',')];
  gFiltered.forEach(g => {
    rows.push(cols.map(c => `"${String(g[c]??'').replace(/"/g,'""')}"`).join(','));
  });
  const blob = new Blob([rows.join('\n')], {type:'text/csv'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `groupdesk_${new Date().toISOString().slice(0,10)}.csv`;
  a.click();
}

// ── Dropdown: delegated click + close on outside click ────────────────────
document.getElementById('userDropdown').addEventListener('click', e => {
  const opt = e.target.closest('[data-idx]');
  if (!opt) return;
  const idx = parseInt(opt.dataset.idx, 10);
  if (!isNaN(idx) && _dropdownUsers[idx]) selectUser(_dropdownUsers[idx]);
});
document.addEventListener('click', e => {
  if (!e.target.closest('.user-search-wrap')) {
    document.getElementById('userDropdown').classList.remove('open');
  }
});

// ── User-group map ─────────────────────────────────────────────────────────
function buildUserGroupMap() {
  const map = {};
  GROUPS.forEach(g => {
    (g.members||[]).forEach(m => {
      if (!map[m.id]) map[m.id] = { memberOf:[], ownerOf:[] };
      map[m.id].memberOf.push({ id:g.id, displayName:g.displayName,
        groupCategory:g.groupCategory, isDynamic:g.isDynamic, ownerSource:g.ownerSource });
    });
    (g.owners||[]).forEach(o => {
      if (!map[o.id]) map[o.id] = { memberOf:[], ownerOf:[] };
      map[o.id].ownerOf.push({ id:g.id, displayName:g.displayName, groupCategory:g.groupCategory });
    });
  });
  return map;
}

// ── Users tab ──────────────────────────────────────────────────────────────
function renderUserCards() {
  const active   = USERS.filter(u => u.isActive && !u.isGuest).length;
  const former   = USERS.filter(u => u.isDisabled).length;
  const guests   = USERS.filter(u => u.isGuest).length;
  const inGroups = USERS.filter(u => {
    const m = USER_GROUP_MAP[u.id];
    return m && (m.memberOf.length + m.ownerOf.length) > 0;
  }).length;
  const maxGroups = USERS.reduce((max, u) => {
    const m = USER_GROUP_MAP[u.id];
    return Math.max(max, m ? m.memberOf.length + m.ownerOf.length : 0);
  }, 0);
  document.getElementById('usrCards').innerHTML = [
    `<div class="card"><div class="card-num">${inGroups}</div><div class="card-label">Users in Groups</div></div>`,
    `<div class="card card-green"><div class="card-num">${active}</div><div class="card-label">Active</div></div>`,
    `<div class="card ${former>0?'card-amber':''}"><div class="card-num">${former}</div><div class="card-label">Inactive</div></div>`,
    `<div class="card"><div class="card-num">${guests}</div><div class="card-label">Guests</div></div>`,
    `<div class="card"><div class="card-num">${maxGroups}</div><div class="card-label">Max Groups (1 user)</div></div>`,
  ].join('');
}

function usrSort(key) {
  if (uSortKey === key) { uSortAsc = !uSortAsc; } else { uSortKey = key; uSortAsc = true; }
  uPage = 1;
  renderUsersTab();
}

function clearUsrFilter() {
  document.getElementById('usrSearch').value = '';
  document.getElementById('usrType').value = '';
  document.getElementById('usrMinGroups').value = '0';
  uPage = 1;
  renderUsersTab();
}

function renderUsersTab() {
  renderUserCards();
  const s       = (document.getElementById('usrSearch')||{}).value || '';
  const type    = (document.getElementById('usrType')||{}).value   || '';
  const minGrps = parseInt((document.getElementById('usrMinGroups')||{}).value || '0');

  uFiltered = USERS.filter(u => {
    if (type === 'active'   && (!u.isActive || u.isGuest)) return false;
    if (type === 'inactive' && !u.isDisabled)              return false;
    if (type === 'guest'    && !u.isGuest)                 return false;
    if (s && !u.displayName.toLowerCase().includes(s.toLowerCase()) &&
             !(u.email||'').toLowerCase().includes(s.toLowerCase()) &&
             !(u.department||'').toLowerCase().includes(s.toLowerCase())) return false;
    if (minGrps > 0) {
      const m = USER_GROUP_MAP[u.id];
      if (!m || (m.memberOf.length + m.ownerOf.length) < minGrps) return false;
    }
    return true;
  });

  uFiltered.sort((a, b) => {
    let av, bv;
    if (uSortKey === '_groups') {
      const am = USER_GROUP_MAP[a.id], bm = USER_GROUP_MAP[b.id];
      av = am ? am.memberOf.length + am.ownerOf.length : 0;
      bv = bm ? bm.memberOf.length + bm.ownerOf.length : 0;
    } else {
      av = a[uSortKey] ?? ''; bv = b[uSortKey] ?? '';
    }
    if (typeof av === 'number') return uSortAsc ? av-bv : bv-av;
    return uSortAsc ? String(av).localeCompare(String(bv)) : String(bv).localeCompare(String(av));
  });

  const start = (uPage-1)*U_PAGE, end = start+U_PAGE;
  const page  = uFiltered.slice(start, end);

  const rows = page.map((u, i) => {
    const idx  = start + i;
    const urid = `ur-${idx}`;
    const uMap = USER_GROUP_MAP[u.id] || { memberOf:[], ownerOf:[] };
    const grpCount = uMap.memberOf.length + uMap.ownerOf.length;

    const nameBadge = u.isDisabled
      ? ' <span class="member-badge badge-disabled">INACTIVE</span>'
      : u.isGuest
        ? ' <span class="member-badge" style="background:#dbeafe;color:#1d4ed8;">GUEST</span>'
        : '';

    return `
      <tr class="group-row" onclick="toggleUserDetail('${urid}','${esc(u.id)}',this)">
        <td style="text-align:center;"><span class="expand-icon">▶</span></td>
        <td><div class="gname" style="${u.isDisabled?'color:#c2410c;':''}">${esc(u.displayName)}${nameBadge}</div></td>
        <td style="font-size:12px;">${esc(u.email)}</td>
        <td style="font-size:12px;">${esc(u.department)||'—'}</td>
        <td style="font-size:12px;">${esc(u.companyName)||'—'}</td>
        <td style="font-size:12px;">${esc(u.jobTitle)||'—'}</td>
        <td style="font-size:12px;">${esc(u.officeLocation)||'—'}</td>
        <td style="font-size:12px;font-weight:${grpCount>0?'700':'400'};">${grpCount}</td>
      </tr>
      <tr class="detail-section" id="${urid}">
        <td colspan="8"><div class="detail-inner" id="udi-${esc(u.id)}"></div></td>
      </tr>`;
  });

  document.getElementById('usrBody').innerHTML = rows.join('');

  const total = uFiltered.length, pages = Math.ceil(total/U_PAGE);
  document.getElementById('usrCount').textContent = `${total} user${total===1?'':'s'}`;
  document.getElementById('usrPager').innerHTML = `
    <div class="pager-btns">
      <button onclick="usrGoPage(${uPage-1})" ${uPage<=1?'disabled':''}>← Prev</button>
      <span style="padding:4px 8px;">Page ${uPage} / ${pages||1}</span>
      <button onclick="usrGoPage(${uPage+1})" ${uPage>=pages?'disabled':''}>Next →</button>
    </div>`;
}

function usrGoPage(p) { uPage = p; renderUsersTab(); }

function toggleUserDetail(urid, userId, row) {
  const sec  = document.getElementById(urid);
  const open = sec.classList.toggle('open');
  row.classList.toggle('expanded', open);
  if (open) {
    const u = USERS.find(u=>u.id===userId);
    const container = document.getElementById(`udi-${userId}`);
    if (u && container) renderUserDetail(userId, u, container);
  }
}

function renderUserDetail(userId, u, container) {
  const uMap   = USER_GROUP_MAP[userId] || { memberOf:[], ownerOf:[] };
  const CAT_CSS2 = { 'Microsoft 365':'tag-m365', 'Security':'tag-sec', 'Distribution':'tag-dist' };

  const memberRows = uMap.memberOf.length
    ? uMap.memberOf.map(g => `<tr>
        <td><span class="tag ${CAT_CSS2[g.groupCategory]||'tag-unknown'}">${esc(g.groupCategory)}</span></td>
        <td>${esc(g.displayName)}</td>
        <td>${!g.isDynamic
          ? `<button class="btn btn-danger btn-sm" onclick="promptRemoveMemberFromUser('${esc(g.id)}','${esc(userId)}','${esc(g.displayName)}',event)">Remove</button>`
          : '<span style="font-size:11px;color:var(--muted);">Dynamic</span>'}</td>
      </tr>`).join('')
    : '<tr><td colspan="3" style="color:var(--muted);font-style:italic;padding:8px 10px;">No group memberships</td></tr>';

  const ownerRows = uMap.ownerOf.length
    ? uMap.ownerOf.map(g => `<tr>
        <td><span class="tag ${CAT_CSS2[g.groupCategory]||'tag-unknown'}">${esc(g.groupCategory)}</span></td>
        <td>${esc(g.displayName)}</td>
        <td><button class="btn btn-danger btn-sm" onclick="promptRemoveOwnerFromUser('${esc(g.id)}','${esc(userId)}','${esc(g.displayName)}',event)">Remove</button></td>
      </tr>`).join('')
    : '<tr><td colspan="3" style="color:var(--muted);font-style:italic;padding:8px 10px;">Not an owner of any groups</td></tr>';

  container.innerHTML = `
    <div style="display:flex;gap:32px;flex-wrap:wrap;">
      <div style="flex:1;min-width:300px;">
        <div class="detail-subtitle">Member of (${uMap.memberOf.length})</div>
        <table class="member-tbl" style="margin-top:6px;">
          <thead><tr><th>Type</th><th>Group</th><th></th></tr></thead>
          <tbody>${memberRows}</tbody>
        </table>
      </div>
      <div style="flex:1;min-width:300px;">
        <div class="detail-subtitle">Owner of (${uMap.ownerOf.length})</div>
        <table class="member-tbl" style="margin-top:6px;">
          <thead><tr><th>Type</th><th>Group</th><th></th></tr></thead>
          <tbody>${ownerRows}</tbody>
        </table>
      </div>
    </div>`;
}

function promptRemoveMemberFromUser(groupId, userId, groupName, e) {
  e.stopPropagation();
  const u = USERS.find(u=>u.id===userId);
  pendingAction = async () => {
    await api(`/api/groups/${groupId}/members/${userId}`, { method:'DELETE' });
    await refreshGroup(groupId);
    updateLogBadge();
    const c = document.getElementById(`udi-${userId}`);
    if (c && u) renderUserDetail(userId, u, c);
  };
  document.getElementById('modalTitle').textContent = 'Remove from group';
  document.getElementById('modalBody').textContent  =
    `Remove "${u?.displayName||userId}" from "${groupName}"? This cannot be undone from this console.`;
  document.getElementById('modalConfirm').textContent = 'Remove';
  document.getElementById('modalOverlay').classList.add('open');
}

function promptRemoveOwnerFromUser(groupId, userId, groupName, e) {
  e.stopPropagation();
  const u = USERS.find(u=>u.id===userId);
  pendingAction = async () => {
    await api(`/api/groups/${groupId}/owners/${userId}`, { method:'DELETE' });
    await refreshGroup(groupId);
    updateLogBadge();
    const c = document.getElementById(`udi-${userId}`);
    if (c && u) renderUserDetail(userId, u, c);
  };
  document.getElementById('modalTitle').textContent = 'Remove owner';
  document.getElementById('modalBody').textContent  =
    `Remove "${u?.displayName||userId}" as owner of "${groupName}"?`;
  document.getElementById('modalConfirm').textContent = 'Remove';
  document.getElementById('modalOverlay').classList.add('open');
}

// ── Sign out ───────────────────────────────────────────────────────────────
async function signOut() {
  try { await api('/api/logout', { method:'POST' }); } catch(_) {}
  GROUPS = []; gFiltered = []; USERS = []; USER_GROUP_MAP = {};
  ['tabGroups','tabUsers','tabLog','tabs','headerRight'].forEach(id => {
    document.getElementById(id).style.display = 'none';
  });
  document.getElementById('headerMeta').textContent = 'Signed out';
  init();
}

init();
</script>

<footer style="text-align:center;padding:24px;font-size:11px;color:#999;border-top:1px solid var(--border);margin-top:32px;">
  Built by <a href="https://github.com/hazplay" target="_blank" rel="noopener" style="color:#6366f1;text-decoration:none;">HazPlay</a>
  &nbsp;·&nbsp; MIT Licence &nbsp;·&nbsp;
  <a href="https://github.com/HazPlay/SomeStuff/tree/main/M365/MgGraph/GroupDesk" target="_blank" rel="noopener" style="color:#6366f1;text-decoration:none;">GitHub</a>
</footer>
</body>
</html>
'@

# ─── Route handler ────────────────────────────────────────────────────────────
function Start-Console {
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$script:Port/")

    try {
        $listener.Start()
        Write-Host ""
        Write-Host "  GroupDesk" -ForegroundColor Cyan
        Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  URL  : http://localhost:$script:Port" -ForegroundColor Gray
        Write-Host "  Ctrl+C to stop" -ForegroundColor DarkGray
        Write-Host ""

        if (-not $NoBrowser) { Start-Process "http://localhost:$script:Port" }

        while ($listener.IsListening) {
            $ctx = $null
            try   { $ctx = $listener.GetContext() }
            catch { break }

            $req    = $ctx.Request
            $res    = $ctx.Response
            $path   = $req.Url.AbsolutePath
            $method = $req.HttpMethod
            $qs     = $req.QueryString

            try {
                # ── Auth check (skip for public routes) ───────────────────
                # /api/logout is public so unauthenticated sessions can still
                # clear any partial state without a 401 loop.
                $publicRoutes = @('/', '/callback', '/api/auth', '/api/progress', '/api/logout')
                if ($path -notin $publicRoutes -and -not $script:Token) {
                    Send-Error $res 'Not authenticated' 401
                    continue
                }

                # ── CSRF: verify Origin on all state-mutating requests ─────
                if ($method -in @('POST','DELETE')) {
                    $origin = $req.Headers['Origin']
                    $allowed = "http://localhost:$script:Port"
                    if ($origin -and $origin -ne $allowed) {
                        Send-Error $res 'Forbidden' 403
                        continue
                    }
                }

                switch ($method) {

                    'GET' {
                        switch -Regex ($path) {
                            '^/$' {
                                Send-Response $res $script:HtmlApp
                            }

                            '^/callback$' {
                                $code  = $qs['code']
                                $state = $qs['state']
                                $err   = $qs['error']

                                if ($err) {
                                    $safeErr = [System.Web.HttpUtility]::HtmlEncode($err)
                                    Send-Response $res "<h2 style='font-family:sans-serif;padding:40px;color:red'>Auth error: $safeErr</h2>"
                                    break
                                }
                                if ($state -ne $script:AuthState) {
                                    Send-Response $res "<h2 style='font-family:sans-serif;padding:40px;color:red'>Invalid state. Please try again.</h2>"
                                    break
                                }

                                try {
                                    Update-Token -Code $code
                                    $script:Me = Invoke-Graph '/me?$select=id,displayName,mail,userPrincipalName' -Raw
                                    Write-Log "Signed in: $($script:Me.displayName) ($($script:Me.mail))" 'OK'
                                    # Clear PKCE one-time values — they must not be reusable
                                    $script:AuthState    = $null
                                    $script:CodeVerifier = $null
                                    $res.Redirect("http://localhost:$script:Port/")
                                    $res.OutputStream.Close()
                                } catch {
                                    Send-Response $res "<h2 style='font-family:sans-serif;padding:40px;color:red'>Token error: $($_.Exception.Message)</h2>"
                                }
                            }

                            '^/api/auth$' {
                                if ($script:Token) {
                                    Send-Json $res @{
                                        authenticated = $true
                                        user = @{
                                            displayName       = $script:Me.displayName
                                            mail              = $script:Me.mail
                                            userPrincipalName = $script:Me.userPrincipalName
                                        }
                                    }
                                } else {
                                    $script:CodeVerifier = New-CodeVerifier
                                    $script:AuthState    = [guid]::NewGuid().ToString('N')
                                    Send-Json $res @{
                                        authenticated = $false
                                        authUrl       = Get-AuthUrl
                                    }
                                }
                            }

                            '^/api/progress$' {
                                Send-Json $res $script:LoadProgress
                            }

                            '^/api/groups$' {
                                if (-not $script:GroupCache) { Load-AllData }
                                Send-Json $res $script:GroupCache
                            }

                            '^/api/groups/([^/]+)$' {
                                $gid = $Matches[1]
                                if (-not (Assert-IsGuid $gid)) { Send-Error $res 'Invalid group ID' 400; break }
                                Sync-CachedGroup $gid
                                $g = $script:GroupCache | Where-Object { $_.id -eq $gid } | Select-Object -First 1
                                if ($g) { Send-Json $res $g }
                                else    { Send-Error $res 'Group not found' 404 }
                            }

                            '^/api/users$' {
                                $users = @($script:UserCache.Values |
                                    Sort-Object displayName |
                                    Select-Object id,displayName,email,department,jobTitle,isDisabled,isGuest,isActive)
                                Send-Json $res $users
                            }

                            '^/api/log$' {
                                Send-Json $res @($script:ActionLog)
                            }

                            default {
                                Send-Error $res 'Not found' 404
                            }
                        }
                    }

                    'POST' {
                        switch -Regex ($path) {
                            '^/api/logout$' {
                                $script:Token        = $null
                                $script:RefreshToken = $null
                                $script:GroupCache   = $null
                                $script:Me           = $null
                                $script:LoadProgress = @{ status='idle'; current=0; total=0; message='' }
                                Write-Log "User signed out" 'OK'
                                Send-Json $res @{ ok = $true }
                            }

                            '^/api/refresh$' {
                                $script:GroupCache = $null
                                $script:LoadProgress = @{ status='idle'; current=0; total=0; message='' }
                                Send-Json $res @{ ok = $true }
                                # Load on next /api/groups request
                            }

                            '^/api/groups/([^/]+)/members$' {
                                $gid  = $Matches[1]
                                if (-not (Assert-IsGuid $gid)) { Send-Error $res 'Invalid group ID' 400; break }
                                $body = Read-Body $req
                                if (-not $body -or -not $body.userId) {
                                    Send-Error $res 'userId required' 400; break
                                }
                                if (-not (Assert-IsGuid $body.userId)) { Send-Error $res 'Invalid user ID' 400; break }
                                Add-GroupMember -GroupId $gid -UserId $body.userId
                                Write-Log "Added member $($body.userId) to $gid" 'OK'
                                Send-Json $res @{ ok = $true }
                            }

                            '^/api/groups/([^/]+)/owners$' {
                                $gid  = $Matches[1]
                                if (-not (Assert-IsGuid $gid)) { Send-Error $res 'Invalid group ID' 400; break }
                                $body = Read-Body $req
                                if (-not $body -or -not $body.userId) {
                                    Send-Error $res 'userId required' 400; break
                                }
                                if (-not (Assert-IsGuid $body.userId)) { Send-Error $res 'Invalid user ID' 400; break }
                                Add-GroupOwner -GroupId $gid -UserId $body.userId
                                Write-Log "Added owner $($body.userId) to $gid" 'OK'
                                Send-Json $res @{ ok = $true }
                            }

                            default { Send-Error $res 'Not found' 404 }
                        }
                    }

                    'DELETE' {
                        switch -Regex ($path) {
                            '^/api/groups/([^/]+)/members/([^/]+)$' {
                                $gid = $Matches[1]; $uid = $Matches[2]
                                if (-not (Assert-IsGuid $gid)) { Send-Error $res 'Invalid group ID' 400; break }
                                if (-not (Assert-IsGuid $uid))  { Send-Error $res 'Invalid user ID' 400; break }
                                Remove-GroupMember -GroupId $gid -UserId $uid
                                Write-Log "Removed member $uid from $gid" 'OK'
                                Send-Json $res @{ ok = $true }
                            }

                            '^/api/groups/([^/]+)/owners/([^/]+)$' {
                                $gid = $Matches[1]; $uid = $Matches[2]
                                if (-not (Assert-IsGuid $gid)) { Send-Error $res 'Invalid group ID' 400; break }
                                if (-not (Assert-IsGuid $uid))  { Send-Error $res 'Invalid user ID' 400; break }
                                Remove-GroupOwner -GroupId $gid -UserId $uid
                                Write-Log "Removed owner $uid from $gid" 'OK'
                                Send-Json $res @{ ok = $true }
                            }

                            default { Send-Error $res 'Not found' 404 }
                        }
                    }

                    default { Send-Error $res 'Method not allowed' 405 }
                }

            } catch {
                Write-Log "Request error: $($_.Exception.Message)" 'ERROR'
                try { Send-Error $res $_.Exception.Message } catch { }
            }
        }
    } finally {
        if ($listener.IsListening) { $listener.Stop() }
        $script:Token        = $null
        $script:RefreshToken = $null
        Write-Host ""
        Write-Log "Console stopped. Credentials cleared." 'OK'
        Write-Host ""
    }
}

# ─── Entry point ──────────────────────────────────────────────────────────────
Start-Console
