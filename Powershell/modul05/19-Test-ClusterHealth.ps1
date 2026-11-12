#requires -Version 5.1
#requires -Modules FailoverClusters, Storage
<#
.SYNOPSIS
    Schritt 19: Abnahme - Gesundheitszustand von Cluster, Netzen, Quorum, CSV und S2D pruefen (nur lesend).
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) oder spaeter durch den Betrieb vom Jump Server. Gibt am Ende alle Befunde aus.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$cluster = $cfg.ClusterName
$issues = New-Object System.Collections.Generic.List[string]

$clusterNodes = Get-ClusterNode -Cluster $cluster
$clusterNodes | Format-Table Name, State, DrainStatus -AutoSize
$clusterNodes | Where-Object State -ne 'Up' | ForEach-Object { $issues.Add("Knoten $($_.Name): $($_.State)") }

$networks = Get-ClusterNetwork -Cluster $cluster
$networks | Format-Table Name, Address, Role, State -AutoSize
$networks | Where-Object State -ne 'Up' | ForEach-Object { $issues.Add("Netz $($_.Name): $($_.State)") }

$quorum = Get-ClusterQuorum -Cluster $cluster
$witness = $quorum.QuorumResource
if (-not $witness -or $witness.State -ne 'Online') { $issues.Add('Witness fehlt oder ist nicht online.') }
Write-Host "Witness: $($witness.Name) [$($witness.State)]"

$csvs = Get-ClusterSharedVolume -Cluster $cluster
$csvs | Format-Table Name, State, OwnerNode -AutoSize
$csvs | Where-Object State -ne 'Online' | ForEach-Object { $issues.Add("CSV $($_.Name): $($_.State)") }

$session = New-CimSession -ComputerName $cluster
try {
    $subsystem = Get-StorageSubSystem -CimSession $session -FriendlyName 'Clustered*'
    $pool = Get-StoragePool -CimSession $session -FriendlyName $cfg.PoolName
    if ($pool.HealthStatus -ne 'Healthy') { $issues.Add("Pool $($pool.FriendlyName): $($pool.HealthStatus)") }

    Get-VirtualDisk -CimSession $session | Where-Object HealthStatus -ne 'Healthy' |
        ForEach-Object { $issues.Add("Virtueller Datentraeger $($_.FriendlyName): $($_.HealthStatus)/$($_.OperationalStatus)") }
    Get-PhysicalDisk -CimSession $session -StoragePool $pool | Where-Object HealthStatus -ne 'Healthy' |
        ForEach-Object { $issues.Add("Physischer Datentraeger $($_.SerialNumber): $($_.HealthStatus)") }
    Get-StorageJob -CimSession $session | Where-Object JobState -eq 'Running' |
        ForEach-Object { $issues.Add("Storage-Job laeuft noch: $($_.Name) ($($_.PercentComplete) %)") }
    $subsystem | Debug-StorageSubSystem |
        ForEach-Object { $issues.Add("Health Service: $($_.FaultingObjectDescription) - $($_.Reason)") }
}
finally {
    Remove-CimSession -CimSession $session
}

if ($issues.Count) {
    Write-Warning "Befunde ($($issues.Count)):"
    $issues | ForEach-Object { Write-Warning "  $_" }
}
else {
    Write-Host "Abnahme OK: $cluster ist gesund." -ForegroundColor Green
}
