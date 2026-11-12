#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 4: Persoenliches Tier-1-Adminkonto fuer den Cluster-Administrator anlegen.
.DESCRIPTION
    Einmalig durch einen AD-Administrator, vom Jump Server.
    Das Konto hat KEINE dauerhaften Adminrechte. Es darf sich nur am Jump Server anmelden;
    Rechte auf den Knoten entstehen ausschliesslich ueber die zeitlich begrenzte JIT-Mitgliedschaft.
    Protected Users: nur Kerberos/AES, keine Delegation, kein NTLM/CredSSP, TGT max. 4 Stunden.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GivenName,
    [Parameter(Mandatory)][string]$Surname,
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$dc = $cfg.DomainController
$sam = $cfg.ClusterAdminAccount

$user = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Server $dc
if (-not $user) {
    $password = Read-Host -AsSecureString "Initialkennwort fuer $sam (Uebergabe nur persoenlich)"
    $user = New-ADUser -Name "$sam ($GivenName $Surname)" -SamAccountName $sam `
        -UserPrincipalName "$sam@$($cfg.DomainFqdn)" -GivenName $GivenName -Surname $Surname `
        -Path $cfg.AccountsOu -AccountPassword $password -ChangePasswordAtLogon $true `
        -Enabled $true -AccountNotDelegated $true -KerberosEncryptionType AES128, AES256 `
        -Description 'Tier 1 Admin Hyper-V-Cluster - Rechte nur per JIT' -Server $dc -PassThru
    Write-Host "Konto angelegt: $sam" -ForegroundColor Green
}

# Protected Users = RID 525
$protectedUsers = Get-ADGroup -Identity "$((Get-ADDomain -Server $dc).DomainSID.Value)-525" -Server $dc
Add-ADGroupMember -Identity $protectedUsers -Members $user -Server $dc

if (Get-ADGroup -Filter "Name -eq '$($cfg.JumpServerUsersGroup)'" -Server $dc) {
    Add-ADGroupMember -Identity $cfg.JumpServerUsersGroup -Members $user -Server $dc
}
else {
    Write-Warning "Gruppe $($cfg.JumpServerUsersGroup) (Anmeldung am Jump Server, Tag 2) nicht gefunden."
}

# Sprachunabhaengig ueber SIDs: -512 Domain Admins, -519 Enterprise Admins, S-1-5-32-544 Administrators
$standing = Get-ADPrincipalGroupMembership -Identity $user -Server $dc | Where-Object {
    $_.Name -in $cfg.JitGroup, $cfg.LocalAdminGroup -or
    $_.SID.Value -match '-(512|519)$' -or $_.SID.Value -eq 'S-1-5-32-544'
}
if ($standing) {
    throw "Dauerhafte privilegierte Mitgliedschaft gefunden: $($standing.Name -join ', ')"
}
Write-Host "$sam ist vorbereitet und hat keine dauerhaften Adminrechte." -ForegroundColor Green
