#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 3: AD-Struktur fuer den Cluster vorbereiten (OU, AGDLP-Gruppen, vorab erstelltes CNO, Delegation).
.DESCRIPTION
    Einmalig durch einen AD-Administrator mit Rechten auf der Tier-1-OU, vom Jump Server.
    - OU fuer Cluster-Knoten und CNO, Knoten werden dorthin verschoben
    - Global  T1-HVCluster-Admins-JIT  (nur zeitlich begrenzte Mitglieder)
    - DomainLocal DL-HVCluster-LocalAdmins (enthaelt die JIT-Gruppe)
    - Global  T1-JIT-Approvers (darf ausschliesslich 'member' der JIT-Gruppe schreiben)
    - CNO deaktiviert vorab anlegen; DL-Gruppe erhaelt Vollzugriff auf das CNO,
      das CNO darf in der Cluster-OU Computerobjekte (VCOs) anlegen.
    Der Cluster-Admin braucht damit KEINE Rechte zum Anlegen von Objekten in AD.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$dc = $cfg.DomainController
$clusterOu = "OU=$($cfg.ClusterOuName),$($cfg.Tier1ServersOu)"
$computerClassGuid = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2'
$memberAttributeGuid = [guid]'bf9679c0-0de6-11d0-a285-00aa003049e2'

if (-not (Get-PSDrive -Name SOAD -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name SOAD -PSProvider ActiveDirectory -Root '//RootDSE/' -Server $dc | Out-Null
}

function Get-OrNewGroup {
    param([string]$Name, [string]$Scope, [string]$Description)
    $group = Get-ADGroup -Filter "Name -eq '$Name'" -Server $dc
    if (-not $group) {
        $group = New-ADGroup -Name $Name -SamAccountName $Name -GroupScope $Scope -GroupCategory Security `
            -Path $cfg.GroupsOu -Description $Description -Server $dc -PassThru
        Set-ADObject -Identity $group -ProtectedFromAccidentalDeletion $true -Server $dc
        Write-Host "Gruppe angelegt: $Name ($Scope)" -ForegroundColor Green
    }
    $group
}

function Add-AdAccessRule {
    param([string]$DistinguishedName, [System.DirectoryServices.ActiveDirectoryAccessRule]$Rule)
    $path = "SOAD:\$DistinguishedName"
    $acl = Get-Acl -Path $path
    $existing = $acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object {
        $_.IdentityReference -eq $Rule.IdentityReference -and
        $_.ActiveDirectoryRights -eq $Rule.ActiveDirectoryRights -and
        $_.ObjectType -eq $Rule.ObjectType -and
        $_.AccessControlType -eq $Rule.AccessControlType
    }
    if ($existing) { return }
    $acl.AddAccessRule($Rule)
    Set-Acl -Path $path -AclObject $acl
    Write-Host "ACE gesetzt auf $DistinguishedName ($($Rule.ActiveDirectoryRights))" -ForegroundColor Green
}

# 1. OU
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$clusterOu'" -Server $dc)) {
    New-ADOrganizationalUnit -Name $cfg.ClusterOuName -Path $cfg.Tier1ServersOu `
        -ProtectedFromAccidentalDeletion $true -Server $dc
    Write-Host "OU angelegt: $clusterOu" -ForegroundColor Green
}

# 2. Gruppen nach AGDLP
$jitGroup = Get-OrNewGroup -Name $cfg.JitGroup -Scope Global `
    -Description 'JIT: Hyper-V-Cluster-Administration, nur Mitgliedschaft mit TTL'
$localAdminGroup = Get-OrNewGroup -Name $cfg.LocalAdminGroup -Scope DomainLocal `
    -Description 'Lokale Administratoren SRV-HV* und Vollzugriff auf das CNO'
$approverGroup = Get-OrNewGroup -Name $cfg.ApproverGroup -Scope Global `
    -Description 'Darf JIT-Mitgliedschaften fuer Tier-1-JIT-Gruppen vergeben'

if (-not (Get-ADGroupMember -Identity $localAdminGroup -Server $dc | Where-Object SID -eq $jitGroup.SID)) {
    Add-ADGroupMember -Identity $localAdminGroup -Members $jitGroup -Server $dc
    Write-Host "$($cfg.JitGroup) -> $($cfg.LocalAdminGroup)" -ForegroundColor Green
}

# 3. Knoten in die Cluster-OU verschieben
foreach ($node in $cfg.Nodes) {
    $computer = Get-ADComputer -Filter "Name -eq '$($node.Name)'" -Server $dc
    if (-not $computer) { Write-Warning "$($node.Name) ist noch nicht in der Domaene."; continue }
    if ($computer.DistinguishedName -notlike "*,$clusterOu") {
        Move-ADObject -Identity $computer -TargetPath $clusterOu -Server $dc
        Write-Host "$($node.Name) -> $clusterOu" -ForegroundColor Green
    }
}

# 4. CNO deaktiviert vorab anlegen (Prestaging)
$cno = Get-ADComputer -Filter "Name -eq '$($cfg.ClusterName)'" -Server $dc
if (-not $cno) {
    $cno = New-ADComputer -Name $cfg.ClusterName -Path $clusterOu -Enabled $false `
        -Description "Cluster Name Object $($cfg.ClusterName) (vorab angelegt)" -Server $dc -PassThru
    Set-ADObject -Identity $cno -ProtectedFromAccidentalDeletion $true -Server $dc
    Write-Host "CNO vorab angelegt (deaktiviert): $($cfg.ClusterName)" -ForegroundColor Green
}

# 5. Delegationen
Add-AdAccessRule -DistinguishedName $cno.DistinguishedName -Rule (
    New-Object System.DirectoryServices.ActiveDirectoryAccessRule($localAdminGroup.SID, 'GenericAll', 'Allow'))

Add-AdAccessRule -DistinguishedName $clusterOu -Rule (
    New-Object System.DirectoryServices.ActiveDirectoryAccessRule($cno.SID, 'ReadProperty', 'Allow'))
Add-AdAccessRule -DistinguishedName $clusterOu -Rule (
    New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $cno.SID, 'CreateChild', 'Allow', $computerClassGuid, 'None'))

Add-AdAccessRule -DistinguishedName $jitGroup.DistinguishedName -Rule (
    New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $approverGroup.SID, 'WriteProperty', 'Allow', $memberAttributeGuid, 'None'))

Write-Host "Fertig. Mitglieder fuer $($cfg.ApproverGroup) manuell und dauerhaft pflegen (Vier-Augen-Prinzip)." -ForegroundColor Cyan
