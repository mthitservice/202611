$modulePath = Split-Path $PSScriptRoot -Parent
. "$modulePath\Pki.Common.ps1"

Describe 'PKI script syntax' {
    foreach ($file in Get-ChildItem $modulePath -Filter '*.ps1' -Recurse) {
        It "parses $($file.Name)" {
            $tokens = $null
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors).Count | Should Be 0
        }
    }
}

Describe 'Native error handling' {
    It 'throws for a failed native tool' {
        { Invoke-PkiNative $env:ComSpec @('/c', 'exit', '7') } | Should Throw
    }

    It 'accepts a successful native tool' {
        { Invoke-PkiNative $env:ComSpec @('/c', 'exit', '0') } | Should Not Throw
    }
}

Describe 'CA publication and hardening configuration' {
    BeforeEach {
        $script:calls = @()
        Mock Invoke-PkiNative {
            param($FilePath, $ArgumentList)
            $script:calls += ,$ArgumentList
        }
        Mock Restart-Service {}
    }

    It 'sets the offline root CRL lifetime and the root AIA for subordinate certificates' {
        Set-PkiCaConfiguration -Role Root -PublicationUri 'http://pki.secureops.local/pki/' -ParentCertificateFile 'SecureOps-RootCA.crt'
        (($script:calls | ForEach-Object { $_ -join '|' }) -contains '-setreg|CA\CRLPeriod|Weeks') | Should Be $true
        (($script:calls | ForEach-Object { $_ -join '|' }) -contains '-setreg|CA\CRLPeriodUnits|26') | Should Be $true
        (($script:calls | ForEach-Object { $_ -join '|' }) -contains '-setreg|CA\CRLOverlapPeriodUnits|14') | Should Be $true
        ($script:calls | Where-Object { $_.Count -gt 1 -and $_[1] -eq 'CA\CACertPublicationURLs' })[2] |
            Should Match '2:http://pki.secureops.local/pki/SecureOps-RootCA.crt$'
    }

    It 'sets a short issuing CRL lifetime without deltas and retains CA substitution tokens' {
        Set-PkiCaConfiguration -Role Issuing -PublicationUri 'http://pki.secureops.local/pki/' -ParentCertificateFile 'SecureOps-IssuingCA01.crt'
        (($script:calls | ForEach-Object { $_ -join '|' }) -contains '-setreg|CA\CRLPeriodUnits|7') | Should Be $true
        (($script:calls | ForEach-Object { $_ -join '|' }) -contains '-setreg|CA\CRLDeltaPeriodUnits|0') | Should Be $true
        (($script:calls | ForEach-Object { $_ -join '|' }) -contains '-setreg|CA\CRLOverlapPeriodUnits|1') | Should Be $true
        ($script:calls | Where-Object { $_.Count -gt 1 -and $_[1] -eq 'CA\CRLPublicationURLs' })[2] |
            Should Match '2:http://pki.secureops.local/pki/%3%8%9.crl$'
    }

    It 'requires encrypted enrollment RPC and disables arbitrary SAN attributes' {
        Set-PkiCaConfiguration -Role Issuing -PublicationUri 'http://pki.secureops.local/pki/' -ParentCertificateFile 'SecureOps-IssuingCA01.crt'
        (($script:calls | ForEach-Object { $_ -join '|' }) -contains '-setreg|CA\InterfaceFlags|+IF_ENFORCEENCRYPTICERTREQUEST') | Should Be $true
        (($script:calls | ForEach-Object { $_ -join '|' }) -contains '-setreg|policy\EditFlags|-EDITF_ATTRIBUTESUBJECTALTNAME2') | Should Be $true
        Assert-MockCalled Restart-Service -Times 1 -Exactly -Scope It
    }
}
