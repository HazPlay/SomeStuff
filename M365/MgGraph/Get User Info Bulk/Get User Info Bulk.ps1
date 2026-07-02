# Install if needed: Install-Module Microsoft.Graph -Scope CurrentUser
#Connect-MgGraph -Scopes "User.Read.All"

$users = @(
    "user@domain.com"
    "user@domain.com"
    # paste the rest here
)

$results = foreach ($upn in $users) {
    $user = Get-MgUser -UserId $upn -Property "DisplayName,UserPrincipalName,Department,JobTitle,OfficeLocation" -ErrorAction SilentlyContinue
    if ($user) {
        [PSCustomObject]@{
            Name       = $user.DisplayName
            UPN        = $user.UserPrincipalName
            Department = $user.Department
            JobTitle   = $user.JobTitle
            Office     = $user.OfficeLocation
        }
    } else {
        [PSCustomObject]@{
            Name       = "NOT FOUND"
            UPN        = $upn
            Department = "--"
            JobTitle   = "--"
            Office     = "--"
        }
    }
}

$results | Format-Table -AutoSize

# Optional: export to CSV
# $results | Export-Csv -Path "$env:USERPROFILE\Desktop\bulk_users.csv" -NoTypeInformation
