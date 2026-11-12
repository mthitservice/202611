#requires -Version 5.1
<#
.SYNOPSIS
    Schritt 11: Hyper-V, Failover Clustering und Storage-Rollen remote installieren, Knoten nacheinander neu starten.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server. Neustarts erfolgen sequenziell und werden per WinRM abgewartet.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$features = 'Hyper-V', 'Failover-Clustering', 'Data-Center-Bridging', 'FS-FileServer',
    'RSAT-Clustering-PowerShell', 'Hyper-V-PowerShell'

foreach ($node in ($cfg.Nodes | ForEach-Object { $_.Name })) {
    $missing = Get-WindowsFeature -ComputerName $node -Name $features | Where-Object { -not $_.Installed }
    if ($missing -and $PSCmdlet.ShouldProcess($node, "Installieren: $($missing.Name -join ', ')")) {
        $result = Install-WindowsFeature -ComputerName $node -Name $missing.Name -IncludeManagementTools
        if (-not $result.Success) { throw "Installation auf $node fehlgeschlagen." }
        if ($result.RestartNeeded -eq 'Yes' -and $PSCmdlet.ShouldProcess($node, 'Neustart und warten')) {
            Write-Host "$node wird neu gestartet ..." -ForegroundColor Cyan
            Restart-Computer -ComputerName $node -Protocol WSMan -Wait -For PowerShell -Timeout 1800 -Delay 15 -Force
        }
    }
    $state = Get-WindowsFeature -ComputerName $node -Name $features
    if ($state | Where-Object { -not $_.Installed }) { throw "Nicht alle Rollen auf $node installiert." }
    Write-Host "$node : Rollen installiert." -ForegroundColor Green
}
