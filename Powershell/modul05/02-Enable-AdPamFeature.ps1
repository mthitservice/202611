#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 2: Aktiviert das AD-Feature "Privileged Access Management" (zeitlich begrenzte Gruppenmitgliedschaft).
.DESCRIPTION
    Einmalig, als zeitlich begrenzter Enterprise Admin, vom Jump Server.
    Voraussetzung: Gesamtstrukturfunktionsebene mindestens Windows Server 2016.
    ACHTUNG: Die Aktivierung ist NICHT umkehrbar.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$dc = $cfg.DomainController

$forest = Get-ADForest -Server $dc
# ADForestMode: 7 = Windows2016Forest
if ([int]$forest.ForestMode -lt 7) {
    throw "Gesamtstrukturfunktionsebene $($forest.ForestMode) ist zu niedrig (mindestens Windows2016Forest)."
}

$feature = Get-ADOptionalFeature -Filter "Name -eq 'Privileged Access Management Feature'" -Server $dc
if ($feature.EnabledScopes.Count -gt 0) {
    Write-Host 'PAM-Feature ist bereits aktiviert.' -ForegroundColor Yellow
    return
}

if ($PSCmdlet.ShouldProcess($forest.Name, 'PAM-Feature dauerhaft aktivieren (nicht umkehrbar)')) {
    Enable-ADOptionalFeature -Identity $feature -Scope ForestOrConfigurationSet `
        -Target $forest.Name -Server $dc -Confirm:$false
    $feature = Get-ADOptionalFeature -Identity $feature -Server $dc
    if ($feature.EnabledScopes.Count -eq 0) { throw 'PAM-Feature wurde nicht aktiviert.' }
    Write-Host 'PAM-Feature aktiviert. Enterprise-Admin-Mitgliedschaft jetzt wieder entfernen.' -ForegroundColor Green
}
