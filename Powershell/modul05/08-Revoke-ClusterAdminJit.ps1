#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 8: JIT-Berechtigung vorzeitig entziehen (nach Abschluss oder im Notfall).
.DESCRIPTION
    Durch einen Freigeber vom Jump Server. Bereits ausgestellte Kerberos-Tickets bleiben bis zu
    ihrem Ablauf (max. Rest-TTL) gueltig; im Notfall zusaetzlich Sitzungen beenden und Konto sperren.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Requester,
    [switch]$DisableAccount,
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Cluster.Common.ps1"
$cfg = Import-ClusterConfig -Path $ConfigPath
$dc = $cfg.DomainController
$user = Get-ADUser -Identity $Requester -Server $dc

$current = Get-JitGroupMember -Group $cfg.JitGroup -Server $dc |
    Where-Object DistinguishedName -eq $user.DistinguishedName
if ($current -and $PSCmdlet.ShouldProcess("$Requester -> $($cfg.JitGroup)", 'JIT entziehen')) {
    Remove-ADGroupMember -Identity $cfg.JitGroup -Members $user -Server $dc -Confirm:$false
    Write-Host "JIT fuer $Requester entzogen." -ForegroundColor Green
}
elseif (-not $current) {
    Write-Host "$Requester hat keine (aktive) JIT-Mitgliedschaft." -ForegroundColor Yellow
}

if ($DisableAccount -and $PSCmdlet.ShouldProcess($Requester, 'Konto deaktivieren (Notfall)')) {
    Disable-ADAccount -Identity $user -Server $dc
    Write-Warning "$Requester deaktiviert. Offene Sitzungen auf Jump Server und Knoten abmelden."
}

Get-JitGroupMember -Group $cfg.JitGroup -Server $dc | Format-Table -AutoSize
