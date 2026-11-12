#requires -Version 5.1
#requires -Modules FailoverClusters
<#
.SYNOPSIS
    Schritt 18: Hochverfuegbare Test-VM auf dem CSV anlegen und Live Migration in beide Richtungen pruefen.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server. Die VM benoetigt kein Betriebssystem fuer den Test.
    Mit -Cleanup wird die Test-VM inkl. VHDX wieder entfernt.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1",
    [switch]$Cleanup
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$cluster = $cfg.ClusterName
$vmName = $cfg.TestVmName
$nodes = @($cfg.Nodes | ForEach-Object { $_.Name })
$csvRoot = "C:\ClusterStorage\$($cfg.TestVmVolume)"
$group = try { Get-ClusterGroup -Cluster $cluster -Name $vmName -ErrorAction Stop } catch { $null }

if ($Cleanup) {
    if ($group -and $PSCmdlet.ShouldProcess($vmName, 'Test-VM und Clusterrolle entfernen')) {
        $owner = $group.OwnerNode.Name
        Stop-ClusterGroup -Cluster $cluster -Name $vmName | Out-Null
        Remove-ClusterGroup -Cluster $cluster -Name $vmName -RemoveResources -Force
        Invoke-Command -ComputerName $owner -ArgumentList $vmName, $csvRoot -ScriptBlock {
            param($vmName, $csvRoot)
            Remove-VM -Name $vmName -Force
            Remove-Item -Path (Join-Path $csvRoot "VHDs\$vmName.vhdx") -Force
        }
        Write-Host "$vmName entfernt." -ForegroundColor Green
    }
    return
}

if (-not $group -and $PSCmdlet.ShouldProcess($vmName, "Test-VM auf $($nodes[0]) anlegen und clustern")) {
    Invoke-Command -ComputerName $nodes[0] -ArgumentList $vmName, $csvRoot, $cfg.SwitchName -ScriptBlock {
        param($vmName, $csvRoot, $switchName)
        if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 1GB -Path (Join-Path $csvRoot 'VMs') `
                -NewVHDPath (Join-Path $csvRoot "VHDs\$vmName.vhdx") -NewVHDSizeBytes 20GB -SwitchName $switchName | Out-Null
        }
    }
    Add-ClusterVirtualMachineRole -Cluster $cluster -VMName $vmName | Out-Null
    Start-ClusterGroup -Cluster $cluster -Name $vmName | Out-Null
}

foreach ($i in 1..2) {
    $owner = (Get-ClusterGroup -Cluster $cluster -Name $vmName).OwnerNode.Name
    $target = $nodes | Where-Object { $_ -ne $owner } | Select-Object -First 1
    if (-not $PSCmdlet.ShouldProcess($vmName, "Live Migration $owner -> $target")) { break }
    $duration = Measure-Command {
        Move-ClusterVirtualMachineRole -Cluster $cluster -Name $vmName -Node $target -MigrationType Live | Out-Null
    }
    $now = (Get-ClusterGroup -Cluster $cluster -Name $vmName).OwnerNode.Name
    if ($now -ne $target) { throw "Live Migration nach $target fehlgeschlagen (Besitzer: $now)." }
    Write-Host ("Live Migration {0} -> {1} in {2:N1} s erfolgreich." -f $owner, $target, $duration.TotalSeconds) -ForegroundColor Green
}
