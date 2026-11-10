#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RootCertificate,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9 ]+$')][string]$ExpectedRootThumbprint,
    [Parameter(Mandatory)][string]$RootCrl,
    [Parameter(Mandatory)][string]$IssuingCertificate,
    [uri]$PublicationUri = 'http://pki.secureops.local/pki/',
    [string]$TransferDirectory = 'C:\PKI-Transfer'
)

. "$PSScriptRoot\Pki.Common.ps1"
Assert-PkiCore
if (-not $PublicationUri.IsAbsoluteUri -or $PublicationUri.Scheme -ne 'http' -or
    $PublicationUri.Query -or $PublicationUri.Fragment) {
    throw 'Use an absolute, anonymous HTTP publication URL without a query or fragment.'
}
foreach ($file in @($RootCertificate, $RootCrl, $IssuingCertificate)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing file: $file" }
}
$root = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $RootCertificate
if ($root.Thumbprint -ne ($ExpectedRootThumbprint -replace ' ', '')) {
    throw 'Root certificate fingerprint does not match the independently verified value.'
}
Invoke-PkiNative certutil.exe @('-addstore', '-f', 'Root', $RootCertificate)
Invoke-PkiNative certutil.exe @('-addstore', '-f', 'Root', $RootCrl)
Invoke-PkiNative certutil.exe @('-verify', '-urlfetch', $IssuingCertificate)
Invoke-PkiNative certutil.exe @('-installcert', $IssuingCertificate)
Start-Service CertSvc
$configuration = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
$caName = $configuration.Active
Set-PkiCaConfiguration -Role Issuing -PublicationUri $PublicationUri -ParentCertificateFile "$caName.crt"
New-Item -ItemType Directory -Path $TransferDirectory -Force | Out-Null
Invoke-PkiNative certutil.exe @('-ca.cert', (Join-Path $TransferDirectory "$caName.crt"))
Copy-Item "$env:SystemRoot\System32\CertSrv\CertEnroll\*.crl" $TransferDirectory
Write-Host 'Publish the issuing certificate and CRL on the separate HTTP host before enrolling clients.'
