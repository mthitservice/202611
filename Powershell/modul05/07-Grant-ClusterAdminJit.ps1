#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 7: JIT-Berechtigung fuer den Cluster-Administrator erteilen (zeitlich begrenzte Mitgliedschaft).
.DESCRIPTION
    Durch ein Mitglied von T1-JIT-Approvers vom Jump Server - niemals durch den Antragsteller selbst.
    Die Mitgliedschaft verfaellt automatisch (PAM-Feature, Schritt 2). Der KDC begrenzt die
    Kerberos-Ticketlaufzeit auf die Restlaufzeit der kuerzesten TTL-Mitgliedschaft.
.EXAMPLE
    .\07-Grant-ClusterAdminJit.ps1 -Requester t1-adm-hvcluster -Hours 4 -Reason 'CHG-2026-1142 Aufbau SRV-HVCL01'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Requester,
    [Parameter(Mandatory)][ValidateLength(8, 300)][string]$Reason,
    [ValidateRange(1, 24)][int]$Hours,
    [switch]$Extend,
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Cluster.Common.ps1"
$cfg = Import-ClusterConfig -Path $ConfigPath
$dc = $cfg.DomainController
if (-not $PSBoundParameters.ContainsKey('Hours')) { $Hours = $cfg.DefaultJitHours }
if ($Hours -gt $cfg.MaxJitHours) { throw "Maximal $($cfg.MaxJitHours) Stunden erlaubt." }

$approver = Get-ADUser -Identity $env:USERNAME -Server $dc
$user = Get-ADUser -Identity $Requester -Server $dc
if ($approver.SID -eq $user.SID) { throw 'Vier-Augen-Prinzip: Selbstfreigabe ist nicht erlaubt.' }
if (-not $user.Enabled) { throw "$Requester ist deaktiviert." }

$members = @(Get-JitGroupMember -Group $cfg.JitGroup -Server $dc)
$permanent = $members | Where-Object Permanent
if ($permanent) {
    throw "Dauerhafte Mitglieder in $($cfg.JitGroup) gefunden - zuerst bereinigen: $($permanent.DistinguishedName -join '; ')"
}
$current = $members | Where-Object DistinguishedName -eq $user.DistinguishedName
if ($current -and -not $Extend) {
    throw "$Requester hat bereits JIT bis $($current.ExpiresAt). Zum Verlaengern -Extend angeben."
}

$ttl = New-TimeSpan -Hours $Hours
if ($PSCmdlet.ShouldProcess("$Requester -> $($cfg.JitGroup)", "JIT fuer $Hours Stunde(n) erteilen")) {
    if ($current) { Remove-ADGroupMember -Identity $cfg.JitGroup -Members $user -Server $dc -Confirm:$false }
    Add-ADGroupMember -Identity $cfg.JitGroup -Members $user -MemberTimeToLive $ttl -Server $dc

    $granted = Get-JitGroupMember -Group $cfg.JitGroup -Server $dc |
        Where-Object DistinguishedName -eq $user.DistinguishedName
    if (-not $granted -or $granted.Permanent) { throw 'TTL-Mitgliedschaft konnte nicht verifiziert werden.' }

    # Nachweis: Transkript (Tag 4) + Ereignis 4728 auf dem DC
    [pscustomobject]@{
        Zeitpunkt = Get-Date -Format s
        Freigeber = $approver.SamAccountName
        Konto     = $user.SamAccountName
        Gruppe    = $cfg.JitGroup
        GueltigBis = $granted.ExpiresAt
        Grund     = $Reason
    } | Format-List
}
