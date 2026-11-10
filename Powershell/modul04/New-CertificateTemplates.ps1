#requires -Version 5.1
#requires -RunAsAdministrator
#requires -Modules ActiveDirectory

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DirectoryServer,
    [string]$ComputerGroup = 'GG_PKI_Computers',
    [string]$WebServerGroup = 'GG_PKI_WebServers',
    [string]$CodeSigningGroup = 'GG_PKI_CodeSigning',
    [string]$EfsGroup = 'GG_PKI_EFS',
    [string]$RecoveryGroup = 'GG_PKI_EFSRecovery'
)

. "$PSScriptRoot\Pki.Common.ps1"
Assert-PkiCore
$rootDse = Get-ADRootDSE -Server $DirectoryServer
$domain = Get-ADDomain -Server $DirectoryServer
$forest = Get-ADForest -Server $DirectoryServer
$forestDomain = Get-ADDomain -Identity $forest.RootDomain -Server $DirectoryServer
$servicesPath = "CN=Public Key Services,CN=Services,$($rootDse.configurationNamingContext)"
$templatePath = "CN=Certificate Templates,$servicesPath"
$oidPath = "CN=OID,$servicesPath"
$oidContainer = Get-ADObject $oidPath -Properties 'msPKI-Cert-Template-OID' -Server $DirectoryServer
$oidBase = [string]$oidContainer.'msPKI-Cert-Template-OID'
if (-not $oidBase) { throw 'The forest certificate-template OID prefix could not be read.' }
$caAccount = Get-ADComputer $env:COMPUTERNAME -Server $DirectoryServer
$definitions = @(
    @{ Name = 'SecureOpsComputer'; Source = 'Machine'; Group = $ComputerGroup; Eku = @('1.3.6.1.5.5.7.3.1', '1.3.6.1.5.5.7.3.2'); Subject = 0x08000000; Auto = $true; Approval = $false },
    @{ Name = 'SecureOpsWebServer'; Source = 'WebServer'; Group = $WebServerGroup; Eku = @('1.3.6.1.5.5.7.3.1'); Subject = 1; Auto = $false; Approval = $true },
    @{ Name = 'SecureOpsCodeSigning'; Source = 'CodeSigning'; Group = $CodeSigningGroup; Eku = @('1.3.6.1.5.5.7.3.3'); Subject = 0x80000000; Auto = $false; Approval = $true },
    @{ Name = 'SecureOpsEFS'; Source = 'EFS'; Group = $EfsGroup; Eku = @('1.3.6.1.4.1.311.10.3.4'); Subject = 0x80000000; Auto = $true; Approval = $false },
    @{ Name = 'SecureOpsEFSRecovery'; Source = 'EFSRecovery'; Group = $RecoveryGroup; Eku = @('1.3.6.1.4.1.311.10.3.4.1'); Subject = 0x80000000; Auto = $false; Approval = $true }
)
$copyAttributes = @(
    'flags', 'pKIDefaultKeySpec', 'pKIKeyUsage', 'pKICriticalExtensions',
    'pKIDefaultCSPs', 'msPKI-Private-Key-Flag', 'msPKI-Enrollment-Flag'
)

# Preflight everything before creating any forest-wide objects.
$plans = foreach ($definition in $definitions) {
    if (Get-ADObject -LDAPFilter "(cn=$($definition.Name))" -SearchBase $templatePath -Server $DirectoryServer) {
        throw "Template already exists: $($definition.Name). Review it instead of overwriting."
    }
    $group = Get-ADGroup $definition.Group -Server $DirectoryServer
    if ($group.GroupCategory -ne 'Security') { throw "Not a security group: $($definition.Group)" }
    $source = Get-ADObject "CN=$($definition.Source),$templatePath" -Properties $copyAttributes -Server $DirectoryServer
    @{ Definition = $definition; Group = $group; Source = $source }
}

$enrollGuid = [guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
$autoEnrollGuid = [guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
foreach ($plan in $plans) {
    $definition = $plan.Definition
    $attributes = @{}
    foreach ($attribute in $copyAttributes) {
        $value = $plan.Source.$attribute
        if ($null -ne $value -and @($value).Count -gt 0) {
            $attributes[$attribute] = $value
            if ($value -is [Microsoft.ActiveDirectory.Management.ADPropertyValueCollection]) {
                if ($value.Count -eq 1) {
                    $attributes[$attribute] = $value[0]
                }
                else {
                    $attributes[$attribute] = [object[]]@($value)
                }
            }
        }
    }
    # Keep the source CSP/key usage for EFS compatibility, but never export or archive keys.
    $attributes['msPKI-Private-Key-Flag'] = [int]$attributes['msPKI-Private-Key-Flag'] -band (-bnot 0x11)
    $attributes['msPKI-Enrollment-Flag'] = $(if ($definition.Approval) { 2 } else { 0 }) -bor
        $(if ($definition.Auto) { 0x20 } else { 0 }) -bor
        $(if ($definition.Source -eq 'EFS') { 8 } else { 0 })
    $attributes['msPKI-Certificate-Name-Flag'] = [int]$definition.Subject
    $attributes['msPKI-Minimal-Key-Size'] = 3072
    $attributes['msPKI-Template-Schema-Version'] = 2
    $attributes['msPKI-Template-Minor-Revision'] = 1
    $attributes['msPKI-RA-Signature'] = 0
    $attributes['revision'] = 100
    $attributes['pKIExtendedKeyUsage'] = [string[]]$definition.Eku
    $attributes['msPKI-Certificate-Application-Policy'] = [string[]]$definition.Eku
    $attributes['pKIExpirationPeriod'] = [BitConverter]::GetBytes(-[TimeSpan]::FromDays(365).Ticks)
    $attributes['pKIOverlapPeriod'] = [BitConverter]::GetBytes(-[TimeSpan]::FromDays(42).Ticks)
    $random = [guid]::NewGuid().ToString('N')
    $oidPart1 = [uint32]::Parse($random.Substring(0, 8), [Globalization.NumberStyles]::HexNumber)
    $oidPart2 = [uint32]::Parse($random.Substring(8, 8), [Globalization.NumberStyles]::HexNumber)
    $oid = "$oidBase.$oidPart1.$oidPart2"
    $attributes['msPKI-Cert-Template-OID'] = $oid

    $acl = New-Object System.DirectoryServices.ActiveDirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $adminSids = @('S-1-5-18', "$($domain.DomainSID)-512", "$($forestDomain.DomainSID)-519")
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier "$($forestDomain.DomainSID)-519"))
    foreach ($sid in $adminSids) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier $sid
        $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $identity, 'GenericAll', 'Allow')))
    }
    foreach ($identity in @(
        (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-11'),
        $caAccount.SID, $plan.Group.SID
    )) {
        $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $identity, 'GenericRead', 'Allow')))
    }
    $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $plan.Group.SID, 'ExtendedRight', 'Allow', $enrollGuid)))
    if ($definition.Auto) {
        $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $plan.Group.SID, 'ExtendedRight', 'Allow', $autoEnrollGuid)))
    }
    $attributes['nTSecurityDescriptor'] = $acl
    New-ADObject -Name ([guid]::NewGuid().ToString()) -Type 'msPKI-Enterprise-Oid' -Path $oidPath `
        -OtherAttributes @{ 'msPKI-Cert-Template-OID' = $oid; flags = 1; displayName = $definition.Name } -Server $DirectoryServer
    New-ADObject -Name $definition.Name -DisplayName $definition.Name -Type pKICertificateTemplate `
        -Path $templatePath -OtherAttributes $attributes -Server $DirectoryServer
    Write-Host "Created $($definition.Name). OID: $oid"
}

# Publication is separate so a replication delay cannot hide a partial deployment.
Write-Host 'Templates created but NOT published. After replication and ACL inspection, publish the five templates as described in the lab.'
