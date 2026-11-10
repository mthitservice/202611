# Tag 4: PowerShell Security - Signierung, JEA und DSC

## Lernziele

Nach Abschluss dieses Moduls können die Teilnehmer:
- PowerShell-Skripte mit Code Signing Zertifikaten signieren
- Just Enough Administration (JEA) für delegierte Administration einrichten
- Desired State Configuration (DSC) für konsistente Serverkonfiguration nutzen
- PowerShell-Sicherheitsrichtlinien implementieren

---

## 1. PowerShell Execution Policies und Skript-Signierung

### 1.1 Execution Policy Übersicht

| Policy | Beschreibung | Empfehlung |
|--------|--------------|------------|
| Restricted | Keine Skripte erlaubt | Workstations |
| AllSigned | Nur signierte Skripte | **Produktionsserver** |
| RemoteSigned | Remote-Skripte müssen signiert sein | Entwicklung |
| Unrestricted | Alle Skripte erlaubt | ⚠️ Nicht empfohlen |

### 1.2 Execution Policy per GPO

```powershell
# Execution Policy für Domäne konfigurieren
# Computer Configuration → Administrative Templates → Windows Components → Windows PowerShell
# → Turn on Script Execution → Enabled → Allow only signed scripts
```

### 1.3 Code Signing Zertifikat erstellen

Für die Enterprise-Variante siehe [Server-Core-PKI-Lab: Code Signing](PKI-Server-Core.md#8-code-signing-und-efs-recovery-agent): zweistufige CA, eigene Vorlage `SecureOpsCodeSigning`, dedizierte Enrollment-Gruppe, CA-Manager-Freigabe und nicht exportierbarer Schlüssel. Die selbstsignierte Variante unten bleibt ausschließlich eine unabhängige Lab-Übung.

```powershell
# Option 1: Selbstsigniert (nur für Test/Lab)
$cert = New-SelfSignedCertificate `
    -Subject "CN=SecureOps Code Signing" `
    -Type CodeSigningCert `
    -CertStoreLocation Cert:\CurrentUser\My `
    -NotAfter (Get-Date).AddYears(3)

# Option 2: Eigene Enterprise-Vorlage aus dem Server-Core-PKI-Lab
# Als berechtigtes Signierkonto ausfuehren; Pending ist vor Freigabe erwartet:
# Get-Certificate -Template SecureOpsCodeSigning -CertStoreLocation Cert:\CurrentUser\My
# Danach Request-ID pruefen/freigeben und im selben Benutzerkontext abholen.

# Zertifikat anzeigen
Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | 
    Format-List Subject, Thumbprint, NotAfter
```

### 1.4 Skript signieren

```powershell
# Signierzertifikat auswählen
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | 
    Where-Object { $_.Subject -like "*SecureOps*" }

# Einzelnes Skript signieren
$scriptPath = "C:\Scripts\MyScript.ps1"
Set-AuthenticodeSignature -FilePath $scriptPath -Certificate $cert

# Alle Skripte in einem Verzeichnis signieren
$scripts = Get-ChildItem -Path "C:\Scripts" -Filter "*.ps1" -Recurse
foreach ($script in $scripts) {
    Set-AuthenticodeSignature -FilePath $script.FullName -Certificate $cert
    Write-Host "Signiert: $($script.Name)" -ForegroundColor Green
}

# Signatur überprüfen
Get-AuthenticodeSignature -FilePath $scriptPath | 
    Select-Object Status, SignerCertificate, TimeStamperCertificate
```

### 1.5 Timestamp Server verwenden

```powershell
# Mit Timestamp Server signieren (Signatur bleibt gültig nach Zertifikatsablauf)
$timestampServer = "http://timestamp.digicert.com"

Set-AuthenticodeSignature -FilePath $scriptPath `
    -Certificate $cert `
    -TimestampServer $timestampServer
```

### 1.6 Microsoft Learn Referenzen

- [About Signing](https://learn.microsoft.com/de-de/powershell/module/microsoft.powershell.core/about/about_signing)
- [Set-AuthenticodeSignature](https://learn.microsoft.com/de-de/powershell/module/microsoft.powershell.security/set-authenticodesignature)

---

## 2. Just Enough Administration (JEA)

### 2.1 Was ist JEA?

**Just Enough Administration (JEA)** ist eine PowerShell-Technologie, die rollenbasierte Delegation ermöglicht, ohne vollständige Administratorrechte zu vergeben.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              JEA-Prinzip                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────┐    ┌─────────────────┐    ┌────────────────────────┐ │
│  │   Helpdesk   │───▶│  JEA Endpoint   │───▶│  Virtuelle Admin       │ │
│  │   Mitarbeiter│    │  (Constrained)  │    │  Session               │ │
│  └──────────────┘    └─────────────────┘    └────────────────────────┘ │
│         │                      │                        │              │
│         │                      ▼                        ▼              │
│         │         ┌─────────────────────────────────────────────┐     │
│   Keine Admin-    │     Nur definierte Cmdlets erlaubt:        │     │
│   Rechte          │     • Get-ADUser                            │     │
│                   │     • Reset-ADAccountPassword               │     │
│                   │     • Unlock-ADAccount                      │     │
│                   │                                             │     │
│                   │     ⛔ New-ADUser NICHT erlaubt             │     │
│                   │     ⛔ Remove-ADUser NICHT erlaubt          │     │
│                   └─────────────────────────────────────────────┘     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 JEA-Komponenten

| Komponente | Dateiendung | Zweck |
|------------|-------------|-------|
| Session Configuration | .pssc | Definiert den Endpunkt und Rollen-Zuordnung |
| Role Capability | .psrc | Definiert erlaubte Cmdlets und Funktionen |

### 2.3 JEA Verzeichnisstruktur erstellen

```powershell
# Standard JEA-Verzeichnisse
$JEABase = "C:\ProgramData\JEA"
$JEAModules = "C:\Program Files\WindowsPowerShell\Modules"

# Verzeichnisse erstellen
$Directories = @(
    "$JEABase\Transcripts",
    "$JEABase\RoleCapabilities",
    "$JEAModules\UserProvisioner\RoleCapabilities"
)

foreach ($dir in $Directories) {
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force
        Write-Host "Erstellt: $dir" -ForegroundColor Green
    }
}
```

### 2.4 Role Capability erstellen (.psrc)

> **Datei im Kurs:** [UserProvisioner.psrc](../Powershell/modul03/UserProvisioner.psrc)

```powershell
# Role Capability für Benutzerverwaltung
$RoleCapabilityPath = "$JEAModules\UserProvisioner\RoleCapabilities\UserProvisioner.psrc"

# Role Capability Parameter
$RoleCapParams = @{
    Path = $RoleCapabilityPath
    Author = "SecureOps Admin"
    CompanyName = "SecureOps GmbH"
    Description = "Erlaubt eingeschränkte Benutzerverwaltung"
    
    # Erlaubte Cmdlets mit Parameterbeschränkungen
    VisibleCmdlets = @(
        'Get-ADUser',
        'Get-ADGroup',
        'Get-ADGroupMember',
        @{
            Name = 'Reset-ADAccountPassword'
            Parameters = @{ Name = 'Identity' }
        },
        @{
            Name = 'Unlock-ADAccount'
            Parameters = @{ Name = 'Identity' }
        },
        @{
            Name = 'Set-ADUser'
            Parameters = @(
                @{ Name = 'Identity' },
                @{ Name = 'Description' },
                @{ Name = 'Office' },
                @{ Name = 'OfficePhone' }
            )
        }
    )
    
    # Erlaubte Funktionen
    VisibleFunctions = @(
        'New-StandardUser',  # Eigene Funktion
        'Get-UserReport'     # Eigene Funktion
    )
    
    # Eigene Funktionen definieren
    FunctionDefinitions = @(
        @{
            Name = 'New-StandardUser'
            ScriptBlock = {
                param(
                    [Parameter(Mandatory)]
                    [string]$FirstName,
                    
                    [Parameter(Mandatory)]
                    [string]$LastName,
                    
                    [Parameter(Mandatory)]
                    [string]$Department
                )
                
                $Username = ($FirstName.Substring(0,1) + $LastName).ToLower()
                $Password = ConvertTo-SecureString "Welcome123!" -AsPlainText -Force
                
                New-ADUser -Name "$FirstName $LastName" `
                    -GivenName $FirstName `
                    -Surname $LastName `
                    -SamAccountName $Username `
                    -UserPrincipalName "$Username@secureops.local" `
                    -Department $Department `
                    -Path "OU=Users,OU=Tier 2,DC=secureops,DC=local" `
                    -AccountPassword $Password `
                    -Enabled $true `
                    -ChangePasswordAtLogon $true
                    
                Write-Output "Benutzer $Username erstellt."
            }
        }
    )
}

New-PSRoleCapabilityFile @RoleCapParams
```

### 2.5 Session Configuration erstellen (.pssc)

> **Datei im Kurs:** [JEA-UserProvision.pssc](../Powershell/modul03/JEA-UserProvision.pssc)

```powershell
# Session Configuration für User Provisioning
$SessionConfigPath = "$JEABase\JEA-UserProvision.pssc"

$SessionConfigParams = @{
    Path = $SessionConfigPath
    SessionType = 'RestrictedRemoteServer'
    
    # Transcript für Audit
    TranscriptDirectory = "$JEABase\Transcripts"
    
    # Als virtuelles Konto ausführen (kein echtes Admin-Konto nötig)
    RunAsVirtualAccount = $true
    
    # Rollen-Zuordnung (AD-Gruppe → Role Capability)
    RoleDefinitions = @{
        'SECUREOPS\GG_Helpdesk' = @{
            RoleCapabilities = 'UserProvisioner'
        }
        'SECUREOPS\GG_HR_UserManagement' = @{
            RoleCapabilities = 'UserProvisioner'
        }
    }
}

New-PSSessionConfigurationFile @SessionConfigParams

# Konfiguration testen
Test-PSSessionConfigurationFile -Path $SessionConfigPath
```

### 2.6 JEA Endpoint registrieren

```powershell
# JEA Endpoint registrieren
Register-PSSessionConfiguration -Name 'UserProvisioner' `
    -Path "$JEABase\JEA-UserProvision.pssc" `
    -Force

# Endpoint überprüfen
Get-PSSessionConfiguration -Name 'UserProvisioner'

# WinRM neustarten
Restart-Service WinRM
```

### 2.7 JEA Endpoint testen

```powershell
# Aus Helpdesk-Benutzer-Sicht verbinden
$cred = Get-Credential -UserName "SECUREOPS\helpdesk01" -Message "Helpdesk Login"

$session = New-PSSession -ComputerName SRV-DC01 `
    -ConfigurationName 'UserProvisioner' `
    -Credential $cred

# Verfügbare Befehle anzeigen
Invoke-Command -Session $session -ScriptBlock {
    Get-Command | Select-Object Name, CommandType
}

# Benutzer erstellen (erlaubt)
Invoke-Command -Session $session -ScriptBlock {
    New-StandardUser -FirstName "Max" -LastName "Mustermann" -Department "IT"
}

# Benutzer löschen (NICHT erlaubt - sollte fehlschlagen)
Invoke-Command -Session $session -ScriptBlock {
    Remove-ADUser -Identity "mmustermann" -Confirm:$false
}

# Session beenden
Remove-PSSession $session
```

### 2.8 Microsoft Learn Referenzen

- [Just Enough Administration](https://learn.microsoft.com/de-de/powershell/scripting/learn/remoting/jea/overview)
- [JEA Role Capabilities](https://learn.microsoft.com/de-de/powershell/scripting/learn/remoting/jea/role-capabilities)
- [JEA Session Configurations](https://learn.microsoft.com/de-de/powershell/scripting/learn/remoting/jea/session-configurations)

---

## 3. Desired State Configuration (DSC)

### 3.1 Was ist DSC?

**Desired State Configuration (DSC)** ist ein PowerShell-basiertes Konfigurationsmanagement-System, das den gewünschten Zustand von Servern deklarativ definiert.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                            DSC-Workflow                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────────┐  │
│  │   DSC        │    │    MOF       │    │   Local Configuration   │  │
│  │   Konfigu-   │───▶│    Datei     │───▶│   Manager (LCM)         │  │
│  │   ration.ps1 │    │              │    │                         │  │
│  └──────────────┘    └──────────────┘    └──────────────────────────┘  │
│         │                   │                        │                 │
│    Deklarativ          Kompiliert            Wendet Konfiguration      │
│    definierter         Machine              auf Server an              │
│    Zustand            Object Format                                    │
│                                                                         │
│  Modi:                                                                  │
│  • ApplyOnly       - Einmalige Anwendung                               │
│  • ApplyAndMonitor - Anwenden + Abweichungen melden                    │
│  • ApplyAndAutoCorrect - Automatische Korrektur bei Abweichungen       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 LCM (Local Configuration Manager) konfigurieren

> **Datei im Kurs:** [LCMEncryptionConfig.ps1](../Powershell/modul02/LCMEncryptionConfig.ps1)

```powershell
# LCM Konfiguration
[DSCLocalConfigurationManager()]
configuration LCMConfig
{
    Node "SRV-APP01"
    {
        Settings
        {
            # Konfigurationsmodus
            ConfigurationMode = "ApplyAndAutoCorrect"
            
            # Wie oft prüfen (Minuten)
            ConfigurationModeFrequencyMins = 30
            
            # Wie oft aktualisieren (Minuten)
            RefreshFrequencyMins = 30
            
            # Modus: Push oder Pull
            RefreshMode = "Push"
            
            # Module überschreiben erlauben
            AllowModuleOverwrite = $true
            
            # Reboot bei Bedarf erlauben
            RebootNodeIfNeeded = $true
            
            # Debug-Modus
            DebugMode = "None"
        }
    }
}

# MOF generieren
LCMConfig -OutputPath "C:\DSC\LCMConfig"

# LCM konfigurieren
Set-DscLocalConfigurationManager -Path "C:\DSC\LCMConfig" -ComputerName "SRV-APP01" -Verbose
```

### 3.3 DSC Konfiguration für Server-Härtung

```powershell
# DSC Konfiguration für gehärteten Windows Server
Configuration SecureWindowsServer
{
    param (
        [string[]]$NodeName = 'localhost'
    )
    
    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName SecurityPolicyDsc
    Import-DscResource -ModuleName AuditPolicyDsc
    
    Node $NodeName
    {
        #region Dienste deaktivieren
        Service DisableBrowser
        {
            Name = 'Browser'
            State = 'Stopped'
            StartupType = 'Disabled'
        }
        
        Service DisableRemoteRegistry
        {
            Name = 'RemoteRegistry'
            State = 'Stopped'
            StartupType = 'Disabled'
        }
        
        Service DisableLLTD
        {
            Name = 'lltdsvc'
            State = 'Stopped'
            StartupType = 'Disabled'
        }
        #endregion
        
        #region Windows Features
        WindowsFeature RemoveSMB1
        {
            Name = 'FS-SMB1'
            Ensure = 'Absent'
        }
        
        WindowsFeature InstallADTools
        {
            Name = 'RSAT-AD-Tools'
            Ensure = 'Present'
        }
        #endregion
        
        #region Registry-Einstellungen
        Registry DisableLLMNR
        {
            Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
            ValueName = 'EnableMulticast'
            ValueData = '0'
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        
        Registry DisableWPAD
        {
            Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Wpad'
            ValueName = 'WpadOverride'
            ValueData = '1'
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        
        Registry DisableTelemetry
        {
            Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
            ValueName = 'AllowTelemetry'
            ValueData = '0'
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        #endregion
        
        #region Firewall
        Script EnableFirewall
        {
            GetScript = {
                $profiles = Get-NetFirewallProfile
                return @{ Result = $profiles.Enabled -join ',' }
            }
            TestScript = {
                $profiles = Get-NetFirewallProfile
                return ($profiles | Where-Object { $_.Enabled -eq $false }).Count -eq 0
            }
            SetScript = {
                Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
            }
        }
        #endregion
    }
}

# Konfiguration kompilieren
SecureWindowsServer -NodeName "SRV-APP01" -OutputPath "C:\DSC\SecureWindowsServer"

# Konfiguration anwenden
Start-DscConfiguration -Path "C:\DSC\SecureWindowsServer" -ComputerName "SRV-APP01" -Wait -Verbose -Force
```

### 3.4 DSC mit Verschlüsselung

```powershell
# MOF-Verschlüsselung für sensible Daten (Passwörter, etc.)
# Zertifikat auf Ziel-Server erstellen
$cert = New-SelfSignedCertificate `
    -Type DocumentEncryptionCertLegacyCsp `
    -DnsName "DSC-SRV-APP01" `
    -HashAlgorithm SHA256 `
    -CertStoreLocation Cert:\LocalMachine\My `
    -KeyExportPolicy Exportable

# Zertifikat exportieren (öffentlicher Schlüssel für Authoring Station)
Export-Certificate -Cert $cert -FilePath "C:\Certs\SRV-APP01-DSC.cer"

# LCM mit Zertifikat konfigurieren
[DSCLocalConfigurationManager()]
configuration LCMEncryption
{
    Node "SRV-APP01"
    {
        Settings
        {
            ConfigurationMode = "ApplyAndMonitor"
            RefreshMode = "Push"
            CertificateID = $cert.Thumbprint
        }
    }
}
```

### 3.5 DSC Pull Server (optional)

```powershell
# Pull Server für zentrale Konfigurationsverwaltung
Configuration DSCPullServer
{
    param ([string]$NodeName = 'SRV-DSC01')
    
    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName xPSDesiredStateConfiguration
    
    Node $NodeName
    {
        WindowsFeature DSCService
        {
            Name = 'DSC-Service'
            Ensure = 'Present'
        }
        
        xDscWebService PullServer
        {
            Ensure = 'Present'
            EndpointName = 'PSDSCPullServer'
            Port = 8080
            PhysicalPath = "$env:SystemDrive\inetpub\PSDSCPullServer"
            CertificateThumbPrint = 'AllowUnencryptedTraffic'
            ModulePath = "$env:ProgramFiles\WindowsPowerShell\DscService\Modules"
            ConfigurationPath = "$env:ProgramFiles\WindowsPowerShell\DscService\Configuration"
            State = 'Started'
            RegistrationKeyPath = "$env:ProgramFiles\WindowsPowerShell\DscService"
            UseSecurityBestPractices = $true
        }
    }
}
```

### 3.6 Microsoft Learn Referenzen

- [DSC Overview](https://learn.microsoft.com/de-de/powershell/dsc/overview)
- [DSC Configurations](https://learn.microsoft.com/de-de/powershell/dsc/configurations/configurations)
- [DSC Resources](https://learn.microsoft.com/de-de/powershell/dsc/resources/resources)

---

## 4. PowerShell Logging und Auditing

### 4.1 Transkription aktivieren

```powershell
# PowerShell Transcription für alle Sessions
$TranscriptPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription"

if (-not (Test-Path $TranscriptPath)) {
    New-Item -Path $TranscriptPath -Force
}

Set-ItemProperty -Path $TranscriptPath -Name "EnableTranscripting" -Value 1
Set-ItemProperty -Path $TranscriptPath -Name "OutputDirectory" -Value "C:\PSTranscripts"
Set-ItemProperty -Path $TranscriptPath -Name "EnableInvocationHeader" -Value 1
```

### 4.2 Script Block Logging

```powershell
# Script Block Logging aktivieren
$ScriptBlockPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"

if (-not (Test-Path $ScriptBlockPath)) {
    New-Item -Path $ScriptBlockPath -Force
}

Set-ItemProperty -Path $ScriptBlockPath -Name "EnableScriptBlockLogging" -Value 1
Set-ItemProperty -Path $ScriptBlockPath -Name "EnableScriptBlockInvocationLogging" -Value 1
```

### 4.3 Module Logging

```powershell
# Module Logging für alle Module
$ModuleLoggingPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging"
$ModuleNamesPath = "$ModuleLoggingPath\ModuleNames"

if (-not (Test-Path $ModuleLoggingPath)) {
    New-Item -Path $ModuleLoggingPath -Force
}
if (-not (Test-Path $ModuleNamesPath)) {
    New-Item -Path $ModuleNamesPath -Force
}

Set-ItemProperty -Path $ModuleLoggingPath -Name "EnableModuleLogging" -Value 1
Set-ItemProperty -Path $ModuleNamesPath -Name "*" -Value "*"  # Alle Module loggen
```

---

## 5. Sicherheitsreferenzen

### 5.1 CVE-Relevante PowerShell Schwachstellen

| CVE | Beschreibung | Mitigation |
|-----|--------------|------------|
| CVE-2019-1166 | PowerShell Core Remote Code Execution | Update auf neueste Version |
| CVE-2020-0601 | CurveBall (Code Signing Bypass) | Zertifikats-Updates |
| CVE-2021-1675 | PrintNightmare (auch PS-relevant) | Disable Print Spooler |

### 5.2 BSI IT-Grundschutz

| Anforderung | Beschreibung |
|-------------|--------------|
| SYS.1.2.2.A8 | Schutz der administrativen Schnittstellen |
| SYS.1.2.2.A12 | Redundanz und Hochverfügbarkeit |
| SYS.1.2.2.A13 | Automatische Dokumentation der Systemkonfiguration |
| SYS.1.2.3.A7 | Verwendung der Windows PowerShell (Edition 2023) |

> **Hinweis:** Die `SYS.1.2.2`-Nummern stammen aus einer älteren Edition; in der Edition 2023 ist für aktuelle Windows Server [SYS.1.2.3](https://www.bsi.bund.de/SharedDocs/Downloads/DE/BSI/Grundschutz/IT-GS-Kompendium_Einzel_PDFs_2023/07_SYS_IT_Systeme/SYS_1_2_3_Windows_Server_Edition_2023.pdf?__blob=publicationFile&v=5) maßgeblich.

---

## 6. Übungen Tag 4

### Übung 4.1: Code Signing
1. Erstellen Sie ein selbstsigniertes Code Signing Zertifikat
2. Signieren Sie ein PowerShell-Skript
3. Setzen Sie die Execution Policy auf "AllSigned"
4. Testen Sie die Ausführung signierter und unsignierter Skripte

### Übung 4.2: JEA Endpoint
1. Erstellen Sie eine Role Capability für Passwort-Reset
2. Erstellen Sie eine Session Configuration
3. Registrieren Sie den JEA Endpoint
4. Testen Sie den Zugriff mit einem nicht-privilegierten Benutzer

### Übung 4.3: DSC Konfiguration
1. Erstellen Sie eine DSC-Konfiguration für Server-Härtung
2. Kompilieren Sie die Konfiguration zu einer MOF-Datei
3. Wenden Sie die Konfiguration auf einen Testserver an
4. Überprüfen Sie den Compliance-Status

### Übung 4.4: PowerShell Logging
1. Aktivieren Sie alle drei Logging-Methoden (Transcription, ScriptBlock, Module)
2. Führen Sie einige Befehle aus
3. Analysieren Sie die generierten Logs

---

## 7. Kursdateien im Repository

Die folgenden Dateien wurden im Kurs erstellt und können als Referenz verwendet werden:

| Datei | Beschreibung |
|-------|--------------|
| [Powershell/modul03/JEA-UserProvision.pssc](../Powershell/modul03/JEA-UserProvision.pssc) | JEA Session Configuration |
| [Powershell/modul03/UserProvisioner.psrc](../Powershell/modul03/UserProvisioner.psrc) | JEA Role Capability |
| [Powershell/modul02/LCMEncryptionConfig.ps1](../Powershell/modul02/LCMEncryptionConfig.ps1) | DSC LCM mit Verschlüsselung |
| [Powershell/modul02/CreateUserDelegated.ps1](../Powershell/modul02/CreateUserDelegated.ps1) | Delegierte Benutzererstellung |
| [Powershell/modul03/init.ps1](../Powershell/modul03/init.ps1) | JEA Initialisierung |

---

## 8. Zusammenfassung

✅ PowerShell-Skripte müssen in Produktionsumgebungen signiert werden  
✅ JEA ermöglicht delegierte Administration ohne vollständige Admin-Rechte  
✅ DSC sorgt für konsistente und automatisierte Serverkonfiguration  
✅ Umfassendes PowerShell-Logging ist für Security und Compliance unerlässlich  
✅ Execution Policy "AllSigned" sollte in Produktionsumgebungen gelten  

---

## Weiterführende Ressourcen

### Microsoft Learn Pfade

- [PowerShell-Sicherheit](https://learn.microsoft.com/de-de/powershell/scripting/learn/security-features)
- [Automatisieren von Windows Server](https://learn.microsoft.com/de-de/training/paths/automate-windows-server-administration-with-powershell/)
- [JEA Implementierung](https://learn.microsoft.com/de-de/powershell/scripting/learn/remoting/jea/overview)
- [DSC Lernen](https://learn.microsoft.com/de-de/powershell/dsc/getting-started/wingettingstarted)

### Sicherheitsressourcen

- [CVE Database](https://cve.mitre.org/)
- [ENISA - EU Cybersecurity](https://www.enisa.europa.eu/)
- [BSI IT-Grundschutz Kompendium](https://www.bsi.bund.de/DE/Themen/Unternehmen-und-Organisationen/Standards-und-Zertifizierung/IT-Grundschutz/IT-Grundschutz-Kompendium/it-grundschutz-kompendium_node.html)
- [CERT-Bund](https://www.bsi.bund.de/DE/Themen/Unternehmen-und-Organisationen/Cyber-Sicherheitslage/Reaktion/CERT-Bund/cert-bund_node.html)
- [CERT-Bund Warn- und Informationsdienst](https://wid.cert-bund.de/portal/wid/shortinfo)
- [BSI-Linkprüfung und PKI-Hardening-Referenzen](Referenzen.md#deutsche-sicherheitsressourcen-bsi)

---

## Kursabschluss

Herzlichen Glückwunsch zum erfolgreichen Abschluss des Kurses **Microsoft Windows 2025 Server SecureOps**!

Sie haben gelernt:
- ✅ Windows Server 2025 sicher zu installieren und zu härten
- ✅ Jump Server und Security Baselines zu implementieren
- ✅ Admin-Domänen und das Tier-Modell aufzubauen
- ✅ PowerShell-Sicherheit mit JEA und DSC zu konfigurieren
