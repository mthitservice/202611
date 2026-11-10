#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Root', 'Issuing')][string]$Role,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]{1,64}$')][string]$CACommonName,
    [uri]$PublicationUri = 'http://pki.secureops.local/pki/',
    [string]$DatabaseDirectory = 'D:\CA\Database',
    [string]$LogDirectory = 'E:\CA\Logs',
    [string]$TransferDirectory = 'C:\PKI-Transfer'
)

. "$PSScriptRoot\Pki.Common.ps1"
Assert-PkiCore
if (-not $PublicationUri.IsAbsoluteUri -or $PublicationUri.Scheme -ne 'http' -or
    $PublicationUri.Query -or $PublicationUri.Fragment) {
    throw 'Use an absolute, anonymous HTTP publication URL without a query or fragment.'
}
$computer = Get-CimInstance Win32_ComputerSystem
if ($Role -eq 'Root' -and $computer.PartOfDomain) {
    throw 'The offline root must be a workgroup server, never a domain member.'
}
if ($Role -eq 'Root' -and @(Get-NetAdapter | Where-Object Status -eq 'Up').Count -gt 0) {
    throw 'Disconnect or disable all root CA network adapters before installation.'
}
if ($Role -eq 'Issuing' -and (-not $computer.PartOfDomain -or $computer.DomainRole -ge 4)) {
    throw 'The issuing CA must be a domain member server, not a domain controller.'
}
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration') {
    throw 'An existing CA configuration was found. This script only installs new CAs.'
}
foreach ($directory in @($DatabaseDirectory, $LogDirectory, $TransferDirectory)) {
    $driveRoot = [IO.Path]::GetPathRoot($directory)
    if ($directory -notmatch '^[A-Za-z]:\\' -or -not (Test-Path $driveRoot)) {
        throw "An existing, absolute local drive is required: $directory"
    }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$policyPath = Join-Path $env:SystemRoot 'CAPolicy.inf'
if (Test-Path $policyPath) {
    throw "Review the existing $policyPath before installing. It will not be overwritten."
}
$pathLength = if ($Role -eq 'Root') { 1 } else { 0 }
$crlPeriod = if ($Role -eq 'Root') { 'Weeks' } else { 'Days' }
$crlUnits = if ($Role -eq 'Root') { 26 } else { 7 }
# Sub-CA-Laufzeit bestimmt die Root; RenewalValidityPeriod nur fuer die Root setzen
$renewalValidity = if ($Role -eq 'Root') { "RenewalValidityPeriod=Years`r`nRenewalValidityPeriodUnits=15`r`n" } else { '' }
$policy = @"
[Version]
Signature="`$Windows NT`$"

"@
if ($Role -eq 'Issuing') {
    $cpsUrl = $PublicationUri.AbsoluteUri.TrimEnd('/') + '/cps.html'
    $policy += @"
[PolicyStatementExtension]
Policies=AllIssuancePolicy
Critical=False

[AllIssuancePolicy]
OID=2.5.29.32.0
Notice="SecureOps Lab PKI. Nutzung nur gemaess Certificate Practice Statement."
URL="$cpsUrl"

"@
}
$policy += @"
[Certsrv_Server]
RenewalKeyLength=4096
$($renewalValidity)CRLPeriod=$crlPeriod
CRLPeriodUnits=$crlUnits
CRLDeltaPeriod=Days
CRLDeltaPeriodUnits=0
LoadDefaultTemplates=0
AlternateSignatureAlgorithm=0

[BasicConstraintsExtension]
PathLength=$pathLength
Critical=Yes
"@
if ($Role -eq 'Root') {
    $policy += @"


[CRLDistributionPoint]
Empty=True

[AuthorityInformationAccess]
Empty=True
"@
}
$policy | Set-Content -Path $policyPath -Encoding Ascii
$feature = Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools
if (-not $feature.Success -or $feature.RestartNeeded -eq 'Yes') {
    throw 'Role installation failed or requires a reboot. Review the result before continuing.'
}
Import-Module ADCSDeployment
$parameters = @{
    CAType               = if ($Role -eq 'Root') { 'StandaloneRootCA' } else { 'EnterpriseSubordinateCA' }
    CACommonName         = $CACommonName
    CryptoProviderName   = 'RSA#Microsoft Software Key Storage Provider'
    KeyLength            = 4096
    HashAlgorithmName    = 'SHA256'
    DatabaseDirectory    = $DatabaseDirectory
    LogDirectory         = $LogDirectory
    Force                = $true
    ErrorAction          = 'Stop'
}
if ($Role -eq 'Root') {
    $parameters.ValidityPeriod = 'Years'
    $parameters.ValidityPeriodUnits = 15
}
else {
    $parameters.OutputCertRequestFile = Join-Path $TransferDirectory "$CACommonName.req"
}
Install-AdcsCertificationAuthority @parameters
if ($Role -eq 'Root') {
    Set-PkiCaConfiguration -Role Root -PublicationUri $PublicationUri -ParentCertificateFile "$CACommonName.crt"
    Invoke-PkiNative certutil.exe @('-ca.cert', (Join-Path $TransferDirectory "$CACommonName.crt"))
    Copy-Item "$env:SystemRoot\System32\CertSrv\CertEnroll\*.crl" $TransferDirectory
    Write-Host 'Export the public certificate and CRL via controlled media, back up the CA, then shut down the root.'
}
else {
    Write-Host "Pending installation. Transfer $TransferDirectory\$CACommonName.req to the offline root."
    Write-Host 'Do not reinstall the CA. Continue with Complete-IssuingCa.ps1 after signing.'
}
