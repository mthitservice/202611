#requires -Version 5.1
#requires -Modules ActiveDirectory
# Gemeinsame Hilfsfunktionen fuer modul05 (dot-sourcen: . "$PSScriptRoot\Cluster.Common.ps1")

function Import-ClusterConfig {
    param([Parameter(Mandatory)][string]$Path)
    Import-PowerShellDataFile -Path $Path
}

function Get-JitGroupMember {
    <# Liefert die Mitglieder der JIT-Gruppe inkl. Restlaufzeit; Mitglieder ohne TTL sind dauerhaft. #>
    param(
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Server
    )
    $entries = (Get-ADGroup -Identity $Group -Properties member -ShowMemberTimeToLive -Server $Server).member
    foreach ($entry in $entries) {
        if ($entry -match '^<TTL=(\d+)>,(.+)$') {
            [pscustomobject]@{
                DistinguishedName = $Matches[2]
                Permanent         = $false
                RemainingMinutes  = [math]::Floor([int]$Matches[1] / 60)
                ExpiresAt         = (Get-Date).AddSeconds([int]$Matches[1])
            }
        }
        else {
            [pscustomobject]@{
                DistinguishedName = $entry
                Permanent         = $true
                RemainingMinutes  = $null
                ExpiresAt         = $null
            }
        }
    }
}
