#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 10: JIT-Zugriff und Voraussetzungen der Knoten pruefen (nur lesend).
.DESCRIPTION
    Als t1-adm-hvcluster auf dem Jump Server. Verwirft vorhandene Kerberos-Tickets, damit das neue
    TGT die JIT-Gruppe enthaelt, und prueft per WinRM auf jedem Knoten:
    Adminrecht ueber die DL-Gruppe, Kerberos, Datacenter-Edition, Virtualisierung, Adapter, Datenplatten.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Cluster.Common.ps1"
$cfg = Import-ClusterConfig -Path $ConfigPath
$dc = $cfg.DomainController
$nodes = $cfg.Nodes | ForEach-Object { $_.Name }

& klist.exe purge | Out-Null
$me = Get-ADUser -Identity $env:USERNAME -Server $dc
$jit = Get-JitGroupMember -Group $cfg.JitGroup -Server $dc | Where-Object DistinguishedName -eq $me.DistinguishedName
if (-not $jit) { throw "Keine aktive JIT-Mitgliedschaft fuer $($me.SamAccountName). Freigabe anfordern (Schritt 7)." }
if ($jit.Permanent) { throw 'Dauerhafte Mitgliedschaft in der JIT-Gruppe - Verstoss gegen das Konzept, Freigeber informieren.' }
Write-Host "JIT aktiv bis $($jit.ExpiresAt) (noch $($jit.RemainingMinutes) Minuten)." -ForegroundColor Green
if ($jit.RemainingMinutes -lt 60) { Write-Warning 'Weniger als 60 Minuten Restlaufzeit - fuer den Clusteraufbau Verlaengerung beantragen.' }

$localAdminSid = (Get-ADGroup -Identity $cfg.LocalAdminGroup -Server $dc).SID.Value
$expectedAdapters = @($cfg.ManagementAdapter) + $cfg.SetAdapters

$report = Invoke-Command -ComputerName $nodes -ArgumentList $localAdminSid, $expectedAdapters -ScriptBlock {
    param($localAdminSid, $expectedAdapters)
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $adapterNames = @(Get-NetAdapter | ForEach-Object Name) +
        @(Get-NetAdapterAdvancedProperty -DisplayName 'Hyper-V Network Adapter Name' -ErrorAction SilentlyContinue |
            ForEach-Object DisplayValue)
    [pscustomobject]@{
        Node           = $env:COMPUTERNAME
        Auth           = $id.AuthenticationType
        IsAdmin        = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        ViaJitGroup    = $id.Groups.Value -contains $localAdminSid
        Datacenter     = $os.Caption -match 'Datacenter'
        Build          = $os.BuildNumber
        DomainMember   = $cs.PartOfDomain
        Virtualization = [bool]($cpu.VirtualizationFirmwareEnabled -or $cs.HypervisorPresent)
        AdaptersFound  = @($expectedAdapters | Where-Object { $_ -in $adapterNames }).Count -eq $expectedAdapters.Count
        DataDisks      = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem }).Count
        ClusterService = [bool](Get-Service ClusSvc -ErrorAction SilentlyContinue)
    }
} | Select-Object Node, Auth, IsAdmin, ViaJitGroup, Datacenter, Build, DomainMember, Virtualization, AdaptersFound, DataDisks, ClusterService

$report | Format-Table -AutoSize

$failed = $report | Where-Object {
    $_.Auth -ne 'Kerberos' -or -not $_.IsAdmin -or -not $_.ViaJitGroup -or -not $_.Datacenter -or
    -not $_.DomainMember -or -not $_.Virtualization -or -not $_.AdaptersFound -or $_.DataDisks -lt 2
}
if ($failed) { throw "Voraussetzungen nicht erfuellt auf: $($failed.Node -join ', ')" }
Write-Host 'Alle Knoten erfuellen die Voraussetzungen.' -ForegroundColor Green
