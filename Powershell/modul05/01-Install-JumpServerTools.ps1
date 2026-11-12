#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Schritt 1: Installiert die Verwaltungswerkzeuge auf dem Jump Server.
.DESCRIPTION
    Einmalig durch den Jump-Server-Administrator. Danach laufen alle Cluster-Schritte
    remote vom Jump Server; auf den Knoten wird nicht interaktiv gearbeitet.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -eq 1) {
    # Windows-Client-PAW: RSAT als Features on Demand
    foreach ($capability in @(
            'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
            'Rsat.FailoverCluster.Management.Tools~~~~0.0.1.0')) {
        if ((Get-WindowsCapability -Online -Name $capability).State -ne 'Installed') {
            Add-WindowsCapability -Online -Name $capability | Out-Null
        }
    }
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -NoRestart | Out-Null
}
else {
    Install-WindowsFeature -Name RSAT-AD-PowerShell, RSAT-Clustering-PowerShell, Hyper-V-PowerShell | Out-Null
}

foreach ($module in 'ActiveDirectory', 'FailoverClusters', 'Hyper-V', 'Storage') {
    if (-not (Get-Module -ListAvailable -Name $module)) { throw "Modul $module fehlt." }
    Write-Host "Modul verfuegbar: $module" -ForegroundColor Green
}
