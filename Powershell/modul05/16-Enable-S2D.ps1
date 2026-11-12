#requires -Version 5.1
#requires -Modules FailoverClusters, Storage
<#
.SYNOPSIS
    Schritt 16: Storage Spaces Direct aktivieren und Cluster Shared Volumes (ReFS, Mirror) anlegen.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server, per CIM-Sitzung auf den Clusternamen.
    Bei zwei Knoten ergibt Mirror einen Two-Way-Mirror; Reservekapazitaet im Pool frei lassen.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$session = New-CimSession -ComputerName $cfg.ClusterName
try {
    if (-not (Get-StoragePool -CimSession $session -FriendlyName $cfg.PoolName -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($cfg.ClusterName, 'Storage Spaces Direct aktivieren')) {
            Enable-ClusterStorageSpacesDirect -CimSession $session -PoolFriendlyName $cfg.PoolName -Confirm:$false
        }
    }

    foreach ($volume in $cfg.Volumes) {
        if (Get-VirtualDisk -CimSession $session -FriendlyName $volume.Name -ErrorAction SilentlyContinue) { continue }
        if ($PSCmdlet.ShouldProcess($volume.Name, "CSV mit $($volume.SizeGB) GB anlegen")) {
            New-Volume -CimSession $session -StoragePoolFriendlyName $cfg.PoolName -FriendlyName $volume.Name `
                -FileSystem CSVFS_ReFS -ResiliencySettingName Mirror -Size ($volume.SizeGB * 1GB) | Out-Null
            Write-Host "Volume $($volume.Name) angelegt." -ForegroundColor Green
        }
    }

    Get-StoragePool -CimSession $session -IsPrimordial $false |
        Format-Table FriendlyName, HealthStatus, OperationalStatus,
            @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } },
            @{ n = 'AllocatedGB'; e = { [math]::Round($_.AllocatedSize / 1GB) } } -AutoSize
    Get-VirtualDisk -CimSession $session |
        Format-Table FriendlyName, ResiliencySettingName, NumberOfDataCopies, HealthStatus, OperationalStatus -AutoSize
    Get-ClusterSharedVolume -Cluster $cfg.ClusterName | Format-Table Name, State, OwnerNode -AutoSize
}
finally {
    Remove-CimSession -CimSession $session
}
