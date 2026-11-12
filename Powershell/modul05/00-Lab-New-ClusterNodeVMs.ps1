#requires -Version 5.1
#requires -RunAsAdministrator
#requires -Modules Hyper-V
<#
.SYNOPSIS
    Schritt 0 (nur Lab): Legt die Cluster-Knoten als verschachtelte Hyper-V-VMs an.
.DESCRIPTION
    Auf dem physischen Lab-Hyper-V-Host ausfuehren, NICHT auf dem Jump Server.
    Je Knoten: Gen2, statischer RAM, Nested Virtualization, vTPM, Netzadapter MGMT/SET1/SET2
    mit Device Naming, MAC-Spoofing fuer SET und leere Datenplatten fuer S2D.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Leaf })][string]$IsoPath,
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1",
    [string]$VmRoot = 'D:\Lab\VMs',
    [string]$ManagementSwitch = 'LabSwitch',
    [string]$StorageSwitch = 'LabStorage',
    [ValidateRange(6, 64)][int]$MemoryGB = 8,
    [ValidateRange(2, 8)][int]$DataDiskCount = 4,
    [ValidateRange(32, 1024)][int]$DataDiskGB = 100
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath

if (-not (Get-VMSwitch -Name $ManagementSwitch -ErrorAction SilentlyContinue)) {
    throw "Management-Switch '$ManagementSwitch' fehlt auf dem Lab-Host."
}
if (-not (Get-VMSwitch -Name $StorageSwitch -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($StorageSwitch, 'Privaten Storage-Switch anlegen')) {
        New-VMSwitch -Name $StorageSwitch -SwitchType Private | Out-Null
    }
}

foreach ($node in $cfg.Nodes) {
    $name = $node.Name
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
        Write-Warning "$name existiert bereits - uebersprungen."
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($name, 'Cluster-Knoten-VM anlegen')) { continue }

    $vmPath = Join-Path $VmRoot $name
    New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
    New-VM -Name $name -Generation 2 -Path $VmRoot -MemoryStartupBytes ($MemoryGB * 1GB) `
        -NewVHDPath (Join-Path $vmPath 'OS.vhdx') -NewVHDSizeBytes 80GB `
        -SwitchName $ManagementSwitch | Out-Null

    # Nested Virtualization erfordert statischen RAM und durchgereichte VT-x/AMD-V-Erweiterungen
    Set-VMMemory -VMName $name -DynamicMemoryEnabled $false
    Set-VMProcessor -VMName $name -Count 4 -ExposeVirtualizationExtensions $true
    Set-VMKeyProtector -VMName $name -NewLocalKeyProtector
    Enable-VMTPM -VMName $name
    Set-VM -Name $name -AutomaticCheckpointsEnabled $false

    Get-VMNetworkAdapter -VMName $name | Rename-VMNetworkAdapter -NewName $cfg.ManagementAdapter
    foreach ($adapter in $cfg.SetAdapters) {
        Add-VMNetworkAdapter -VMName $name -Name $adapter -SwitchName $StorageSwitch
    }
    # Device Naming: Gast sieht den Adapternamen; MAC-Spoofing fuer Nested-VMs/SET
    Get-VMNetworkAdapter -VMName $name | Set-VMNetworkAdapter -DeviceNaming On -MacAddressSpoofing On

    $dataPath = Join-Path $vmPath 'Data'
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
    for ($i = 1; $i -le $DataDiskCount; $i++) {
        $vhd = Join-Path $dataPath ("Data{0:D2}.vhdx" -f $i)
        New-VHD -Path $vhd -SizeBytes ($DataDiskGB * 1GB) -Dynamic | Out-Null
        Add-VMHardDiskDrive -VMName $name -ControllerType SCSI -Path $vhd
    }

    $dvd = Add-VMDvdDrive -VMName $name -Path $IsoPath -Passthru
    Set-VMFirmware -VMName $name -FirstBootDevice $dvd
    Write-Host "$name angelegt. Windows Server 2025 Datacenter (Core) installieren." -ForegroundColor Green
}
