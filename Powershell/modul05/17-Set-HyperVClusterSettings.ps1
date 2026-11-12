#requires -Version 5.1
#requires -Modules FailoverClusters
<#
.SYNOPSIS
    Schritt 17: Hyper-V-Standardpfade auf CSV und Live Migration ueber die SMB-Netze konfigurieren.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server.
    Live Migration: SMB-Transport (nutzt SMB Multichannel/RDMA), Management-Netz ausgeschlossen.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1",
    [ValidateRange(1, 8)][int]$MaxLiveMigrations = 2
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$nodes = $cfg.Nodes | ForEach-Object { $_.Name }
$csvRoot = "C:\ClusterStorage\$($cfg.TestVmVolume)"

if ($PSCmdlet.ShouldProcess(($nodes -join ', '), "Hyper-V-Pfade auf $csvRoot und Live Migration setzen")) {
    Invoke-Command -ComputerName $nodes -ArgumentList $csvRoot, $MaxLiveMigrations -ScriptBlock {
        param($csvRoot, $maxMigrations)
        if (-not (Test-Path $csvRoot)) { throw "CSV $csvRoot fehlt auf $env:COMPUTERNAME." }
        foreach ($folder in 'VMs', 'VHDs') { New-Item -ItemType Directory -Path (Join-Path $csvRoot $folder) -Force | Out-Null }
        Set-VMHost -VirtualMachinePath (Join-Path $csvRoot 'VMs') -VirtualHardDiskPath (Join-Path $csvRoot 'VHDs')
        Enable-VMMigration
        Set-VMHost -VirtualMachineMigrationAuthenticationType Kerberos `
            -VirtualMachineMigrationPerformanceOption SMB `
            -MaximumVirtualMachineMigrations $maxMigrations -MaximumStorageMigrations $maxMigrations
        Get-VMHost | Select-Object @{ n = 'Node'; e = { $env:COMPUTERNAME } }, VirtualMachinePath,
            VirtualMachineMigrationPerformanceOption, MaximumVirtualMachineMigrations
    } | Select-Object Node, VirtualMachinePath, VirtualMachineMigrationPerformanceOption, MaximumVirtualMachineMigrations |
        Format-Table -AutoSize
}

# Clusterweite Live Migration: alle Netze mit Client-Zugriff (Management) ausschliessen
$exclude = Get-ClusterNetwork -Cluster $cfg.ClusterName | Where-Object { [int]$_.Role -ne 1 }
if ($PSCmdlet.ShouldProcess($cfg.ClusterName, "Live Migration ohne: $($exclude.Name -join ', ')")) {
    Get-ClusterResourceType -Cluster $cfg.ClusterName -Name 'Virtual Machine' |
        Set-ClusterParameter -Name MigrationExcludeNetworks -Value ([string]::Join(';', @($exclude.Id)))
}
Get-ClusterResourceType -Cluster $cfg.ClusterName -Name 'Virtual Machine' |
    Get-ClusterParameter -Name MigrationExcludeNetworks | Format-Table Name, Value -AutoSize
