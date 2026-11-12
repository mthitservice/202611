#requires -Version 5.1
<#
.SYNOPSIS
    Schritt 5: DL-Gruppe in die lokalen Administratoren der Cluster-Knoten aufnehmen.
.DESCRIPTION
    Einmalig durch den Tier-1-Serveradministrator, der die Knoten in die Domaene aufgenommen hat.
    Produktiv besser per GPO (Restricted Groups / Gruppenrichtlinien-Einstellungen) auf die Cluster-OU.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$nodes = $cfg.Nodes | ForEach-Object { $_.Name }
$member = "$($cfg.DomainNetbios)\$($cfg.LocalAdminGroup)"

Invoke-Command -ComputerName $nodes -ScriptBlock {
    # S-1-5-32-544 = lokale Administratoren (sprachunabhaengig)
    $admins = Get-LocalGroup -SID 'S-1-5-32-544'
    if (-not (Get-LocalGroupMember -Group $admins | Where-Object Name -eq $using:member)) {
        Add-LocalGroupMember -Group $admins -Member $using:member
    }
    [pscustomobject]@{
        Node    = $env:COMPUTERNAME
        Members = (Get-LocalGroupMember -Group $admins).Name -join '; '
    }
} | Select-Object Node, Members | Format-Table -AutoSize -Wrap
