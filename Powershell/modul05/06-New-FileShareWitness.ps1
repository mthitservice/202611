#requires -Version 5.1
<#
.SYNOPSIS
    Schritt 6: File Share Witness auf dem Fileserver anlegen; Zugriff nur fuer das CNO.
.DESCRIPTION
    Einmalig durch den Fileserver-Administrator, vom Jump Server.
    Das CNO existiert durch Schritt 3 bereits (deaktiviert), daher kann es vorab berechtigt werden.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$cnoAccount = "$($cfg.DomainNetbios)\$($cfg.ClusterName)$"
$witnessPath = $cfg.WitnessPath
$witnessShare = $cfg.WitnessShare
$clusterName = $cfg.ClusterName

Invoke-Command -ComputerName $cfg.WitnessServer -ScriptBlock {
    $path = $using:witnessPath
    $share = $using:witnessShare
    New-Item -ItemType Directory -Path $path -Force | Out-Null

    # NTFS: Vererbung entfernen, nur SYSTEM, Administratoren und CNO
    & icacls.exe $path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "$($using:cnoAccount):(OI)(CI)M" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls fehlgeschlagen ($LASTEXITCODE)." }

    if (-not (Get-SmbShare -Name $share -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $share -Path $path -FullAccess $using:cnoAccount -EncryptData $true `
            -FolderEnumerationMode AccessBased -Description "Cluster Witness $($using:clusterName)" | Out-Null
    }
    Get-SmbShareAccess -Name $share | Select-Object Name, AccountName, AccessRight
}
