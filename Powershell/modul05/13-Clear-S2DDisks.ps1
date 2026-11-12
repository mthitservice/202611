#requires -Version 5.1
<#
.SYNOPSIS
    Schritt 13: Datenplatten fuer Storage Spaces Direct leeren (DESTRUKTIV).
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server. Nur auf NEUEN Knoten, die noch kein Clustermitglied sind.
    Zeigt je Knoten die betroffenen Nicht-Boot-/Nicht-System-Datentraeger und fragt vor dem Loeschen nach.
    Mit -WhatIf nur anzeigen.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string[]]$Node,
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
if (-not $Node) { $Node = $cfg.Nodes | ForEach-Object { $_.Name } }

foreach ($computer in $Node) {
    $disks = Invoke-Command -ComputerName $computer -ScriptBlock {
        if ((Get-Service ClusSvc -ErrorAction SilentlyContinue).Status -eq 'Running') {
            throw "$env:COMPUTERNAME ist bereits Clustermitglied - Abbruch."
        }
        Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } |
            Select-Object Number, FriendlyName, SerialNumber, BusType, PartitionStyle,
                @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } }
    } | Select-Object Number, FriendlyName, SerialNumber, BusType, PartitionStyle, SizeGB

    Write-Host "`n$computer - betroffene Datentraeger:" -ForegroundColor Cyan
    $disks | Format-Table -AutoSize
    if (-not $disks) { continue }

    if ($PSCmdlet.ShouldProcess("$computer ($(@($disks).Count) Datentraeger)", 'Pools, Partitionen und ALLE Daten loeschen')) {
        Invoke-Command -ComputerName $computer -ArgumentList (, [int[]]$disks.Number) -ScriptBlock {
            param([int[]]$numbers)
            $ErrorActionPreference = 'Stop'
            Update-StorageProviderCache
            foreach ($pool in @(Get-StoragePool -IsPrimordial $false -ErrorAction SilentlyContinue)) {
                $pool | Set-StoragePool -IsReadOnly $false
                $pool | Get-VirtualDisk | Remove-VirtualDisk -Confirm:$false
                $pool | Remove-StoragePool -Confirm:$false
            }
            Get-PhysicalDisk | Where-Object { [int]$_.DeviceId -in $numbers } | Reset-PhysicalDisk
            foreach ($number in $numbers) {
                $disk = Get-Disk -Number $number
                if ($disk.IsOffline) { Set-Disk -Number $number -IsOffline $false }
                if ($disk.IsReadOnly) { Set-Disk -Number $number -IsReadOnly $false }
                if ($disk.PartitionStyle -ne 'RAW') { Clear-Disk -Number $number -RemoveData -RemoveOEM -Confirm:$false }
                Set-Disk -Number $number -IsReadOnly $true
                Set-Disk -Number $number -IsOffline $true
            }
            [pscustomobject]@{
                Node    = $env:COMPUTERNAME
                CanPool = @(Get-PhysicalDisk -CanPool $true).Count
            }
        } | Select-Object Node, CanPool | Format-Table -AutoSize
    }
}
