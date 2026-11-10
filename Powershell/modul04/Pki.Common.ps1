#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-PkiNative {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed (exit code $LASTEXITCODE): $($ArgumentList -join ' ')"
    }
}

function Assert-PkiCore {
    $installation = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ($installation.InstallationType -ne 'Server Core') {
        throw 'This lab requires Windows Server Core.'
    }
}

function Set-PkiCaConfiguration {
    param(
        [Parameter(Mandatory)][ValidateSet('Root', 'Issuing')][string]$Role,
        [Parameter(Mandatory)][uri]$PublicationUri,
        [Parameter(Mandatory)][string]$ParentCertificateFile
    )

    $baseUrl = $PublicationUri.AbsoluteUri.TrimEnd('/')
    $publishPath = Join-Path $env:SystemRoot 'System32\CertSrv\CertEnroll'
    Invoke-PkiNative certutil.exe @('-setreg', 'CA\CRLPublicationURLs',
        "1:$publishPath\%3%8%9.crl\n2:$baseUrl/%3%8%9.crl")
    Invoke-PkiNative certutil.exe @('-setreg', 'CA\CACertPublicationURLs',
        "1:$publishPath\%1_%3%4.crt\n2:$baseUrl/$ParentCertificateFile")
    Invoke-PkiNative certutil.exe @('-setreg', 'CA\CRLPeriod', $(if ($Role -eq 'Root') { 'Weeks' } else { 'Days' }))
    Invoke-PkiNative certutil.exe @('-setreg', 'CA\CRLPeriodUnits', $(if ($Role -eq 'Root') { '26' } else { '7' }))
    Invoke-PkiNative certutil.exe @('-setreg', 'CA\CRLOverlapPeriod', 'Days')
    Invoke-PkiNative certutil.exe @('-setreg', 'CA\CRLOverlapPeriodUnits', $(if ($Role -eq 'Root') { '14' } else { '1' }))
    Invoke-PkiNative certutil.exe @('-setreg', 'CA\CRLDeltaPeriodUnits', '0')
    Invoke-PkiNative certutil.exe @('-setreg', 'CA\ValidityPeriod', 'Years')
    Invoke-PkiNative certutil.exe @('-setreg', 'CA\ValidityPeriodUnits', $(if ($Role -eq 'Root') { '5' } else { '2' }))
    Invoke-PkiNative certutil.exe @('-setreg', 'CA\AuditFilter', '127')
    Invoke-PkiNative certutil.exe @('-setreg', 'CA\InterfaceFlags', '+IF_ENFORCEENCRYPTICERTREQUEST')
    Invoke-PkiNative certutil.exe @('-setreg', 'policy\EditFlags', '-EDITF_ATTRIBUTESUBJECTALTNAME2')
    Restart-Service CertSvc
    Invoke-PkiNative certutil.exe @('-crl')
}
