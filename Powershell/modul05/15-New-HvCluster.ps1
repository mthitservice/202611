#requires -Version 5.1
#requires -Modules FailoverClusters
<#
.SYNOPSIS
    Schritt 15: Cluster mit vorab angelegtem CNO erstellen, Netzwerke benennen und File Share Witness setzen.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server. -NoStorage: Datenplatten werden erst durch S2D (Schritt 16) verwendet.
    Das deaktivierte CNO aus Schritt 3 wird durch New-Cluster aktiviert (Vollzugriff ueber die DL-Gruppe).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$nodes = $cfg.Nodes | ForEach-Object { $_.Name }

$cluster = try { Get-Cluster -Name $cfg.ClusterName -ErrorAction Stop } catch { $null }
if (-not $cluster -and $PSCmdlet.ShouldProcess($cfg.ClusterName, "Cluster aus $($nodes -join ', ') erstellen")) {
    $cluster = New-Cluster -Name $cfg.ClusterName -Node $nodes -StaticAddress $cfg.ClusterIp `
        -NoStorage -AdministrativeAccessPoint ActiveDirectoryAndDns
    Write-Host "Cluster $($cfg.ClusterName) erstellt." -ForegroundColor Green
}
if (-not $cluster) { return }

# Netzwerke anhand des Subnetzes benennen und Rolle setzen
foreach ($definition in $cfg.ClusterNetworks) {
    $network = Get-ClusterNetwork -Cluster $cluster | Where-Object Address -eq $definition.Address
    if (-not $network) { Write-Warning "Clusternetz $($definition.Address) nicht gefunden."; continue }
    if ($network.Name -ne $definition.Name) { $network.Name = $definition.Name }
    if ([int]$network.Role -ne $definition.Role) { $network.Role = $definition.Role }
}

$witness = "\\$($cfg.WitnessServer)\$($cfg.WitnessShare)"
$quorum = Get-ClusterQuorum -Cluster $cluster
if ($quorum.QuorumResource.ResourceType.Name -ne 'File Share Witness' -and
    $PSCmdlet.ShouldProcess($cfg.ClusterName, "File Share Witness $witness setzen")) {
    Set-ClusterQuorum -Cluster $cluster -FileShareWitness $witness | Out-Null
}

Get-ClusterNode -Cluster $cluster | Format-Table Name, State -AutoSize
Get-ClusterNetwork -Cluster $cluster | Format-Table Name, Address, Role, State -AutoSize
Get-ClusterQuorum -Cluster $cluster | Format-List Cluster, QuorumResource
