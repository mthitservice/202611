#requires -Version 5.1
#requires -Modules FailoverClusters
<#
.SYNOPSIS
    Schritt 14: SMB-Konnektivitaet pruefen und Clustervalidierung inkl. Storage Spaces Direct ausfuehren.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server. Test-Cluster laeuft bewusst VOM Jump Server
    (kein Double Hop, keine Kerberos-Delegation fuer das Protected-Users-Konto noetig).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1",
    [string]$ReportDirectory = "$env:USERPROFILE\Documents\ClusterValidation"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$nodes = $cfg.Nodes | ForEach-Object { $_.Name }

$smbTargets = $cfg.Nodes | ForEach-Object { @{ Node = $_.Name; Ips = @($_.Smb1Ip, $_.Smb2Ip) } }
$connectivity = Invoke-Command -ComputerName $nodes -ArgumentList (, $smbTargets) -ScriptBlock {
    param($targets)
    foreach ($target in $targets | Where-Object { $_.Node -ne $env:COMPUTERNAME }) {
        foreach ($ip in $target.Ips) {
            [pscustomobject]@{
                From   = $env:COMPUTERNAME
                To     = "$($target.Node) ($ip)"
                Smb445 = (Test-NetConnection -ComputerName $ip -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded
            }
        }
    }
} | Select-Object From, To, Smb445
$connectivity | Format-Table -AutoSize
if ($connectivity | Where-Object { -not $_.Smb445 }) { throw 'SMB-Verbindung zwischen Knoten fehlgeschlagen - Netz/Firewall pruefen (Schritt 12).' }

New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
$reportName = Join-Path $ReportDirectory ("{0}-{1:yyyyMMdd-HHmm}" -f $cfg.ClusterName, (Get-Date))
$report = Test-Cluster -Node $nodes -ReportName $reportName `
    -Include 'Storage Spaces Direct', 'Inventory', 'Network', 'System Configuration', 'Hyper-V Configuration'
Write-Host "Validierungsbericht: $($report.FullName)" -ForegroundColor Cyan
Write-Host 'Bericht auf der PAW pruefen. Fehler beheben; Warnungen bewerten und dokumentieren.' -ForegroundColor Yellow
