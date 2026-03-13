# Tag 2: Jump Server - Privileged Access Workstations und Security Baselines

## Lernziele

Nach Abschluss dieses Moduls können die Teilnehmer:
- Das Konzept von Jump Servern (PAW - Privileged Access Workstations) verstehen und implementieren
- Microsoft Security Baselines anwenden
- Netzwerksegmentierung für privilegierten Zugriff konfigurieren
- Windows Admin Center für die Remote-Verwaltung einrichten

---

## 1. Jump Server Konzept

### 1.1 Was ist ein Jump Server?

Ein **Jump Server** (auch Bastion Host oder PAW) ist ein dedizierter, gehärteter Server, der als einziger Zugangspunkt für die Administration sensibler Systeme dient.

```
┌──────────────────────────────────────────────────────────────────┐
│                        Sicherheitszonen                          │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │   Tier 2    │    │   Tier 1    │    │       Tier 0        │  │
│  │ Workstation │───▶│ Jump Server │───▶│ Domain Controllers  │  │
│  │             │    │    (PAW)    │    │ Admin Accounts      │  │
│  └─────────────┘    └─────────────┘    └─────────────────────┘  │
│                           │                                      │
│        Nur RDP            │          Nur von Jump Server         │
│        mit MFA            │          erreichbar                  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 Warum Jump Server?

| Problem ohne Jump Server | Lösung mit Jump Server |
|--------------------------|------------------------|
| Direkte Admin-Zugriffe von Workstations | Isolierte Verwaltungszone |
| Credential Theft durch Pass-the-Hash | Credentials nur auf Jump Server |
| Malware kann Admin-Sessions kapern | Gehärtete Umgebung ohne Internet |
| Keine Nachverfolgbarkeit | Zentrale Logging-Punkt |

### 1.3 Microsoft Learn Referenzen

- [Privileged Access Workstations](https://learn.microsoft.com/de-de/security/privileged-access-workstations/privileged-access-workstations)
- [Securing Privileged Access](https://learn.microsoft.com/de-de/security/privileged-access-workstations/overview)
- [Enterprise Access Model](https://learn.microsoft.com/de-de/security/privileged-access-workstations/privileged-access-access-model)

---

## 2. Jump Server Installation

### 2.1 Voraussetzungen

```powershell
# Systemanforderungen prüfen
$requirements = @{
    'RAM (GB)' = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB
    'CPU Cores' = (Get-CimInstance Win32_Processor).NumberOfCores
    'Free Disk (GB)' = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 2)
}
$requirements
```

### 2.2 Windows Server 2025 Core als Jump Server

```powershell
# Jump Server Rolle - Nur notwendige Features
Install-WindowsFeature -Name `
    RSAT-AD-Tools, `
    RSAT-DNS-Server, `
    RSAT-DHCP, `
    Web-Mgmt-Console `
    -IncludeAllSubFeature

# Remote Desktop aktivieren
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name "fDenyTSConnections" -Value 0

# Firewall-Regel für RDP
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Network Level Authentication erzwingen
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
    -Name "UserAuthentication" -Value 1
```

### 2.3 Netzwerkkonfiguration

```powershell
# Zwei Netzwerkadapter konfigurieren
# Adapter 1: Management-Netzwerk (zu Workstations)
# Adapter 2: Server-Netzwerk (zu DCs und Servern)

# Management Interface
$MgmtAdapter = Get-NetAdapter | Where-Object { $_.Name -eq "Ethernet 0" }
New-NetIPAddress -InterfaceIndex $MgmtAdapter.ifIndex `
    -IPAddress "192.168.100.10" `
    -PrefixLength 24 `
    -DefaultGateway "192.168.100.1"

# Server Interface (kein Gateway - nur lokales Routing)
$ServerAdapter = Get-NetAdapter | Where-Object { $_.Name -eq "Ethernet 1" }
New-NetIPAddress -InterfaceIndex $ServerAdapter.ifIndex `
    -IPAddress "10.0.0.10" `
    -PrefixLength 24
# KEIN Gateway - verhindert Internet-Routing

# DNS nur auf Server-Netzwerk
Set-DnsClientServerAddress -InterfaceIndex $ServerAdapter.ifIndex `
    -ServerAddresses "10.0.0.1", "10.0.0.2"
```

---

## 3. Microsoft Security Baselines

### 3.1 Was sind Security Baselines?

Microsoft Security Baselines sind vorkonfigurierte **Gruppenrichtlinien-Einstellungen**, die von Microsoft als sichere Standardkonfiguration empfohlen werden.

### 3.2 Download und Installation

```powershell
# Security Compliance Toolkit herunterladen
# https://www.microsoft.com/en-us/download/details.aspx?id=55319

# Manuelle Installation:
# 1. Download Windows Server 2025 Security Baseline
# 2. Extrahieren nach C:\SecurityBaselines

# Baseline-Struktur
$baselinePath = "C:\SecurityBaselines"
Get-ChildItem -Path $baselinePath -Recurse -Filter "*.admx"
```

### 3.3 Baseline mit LGPO anwenden (Standalone)

```powershell
# LGPO.exe für lokale GPO-Anwendung
# Für Domain Controller:
$DCBaseline = "C:\SecurityBaselines\Windows Server 2025\GPOs\DC"
.\LGPO.exe /g $DCBaseline

# Für Member Server:
$MSBaseline = "C:\SecurityBaselines\Windows Server 2025\GPOs\Member Server"
.\LGPO.exe /g $MSBaseline

# Ergebnis prüfen
gpresult /r
```

### 3.4 Baseline importieren (Active Directory)

```powershell
# GPO in AD importieren
$GPOName = "WS2025 Security Baseline"
$BackupPath = "C:\SecurityBaselines\Windows Server 2025\GPOs\DC"

# Neue GPO erstellen
New-GPO -Name $GPOName

# Baseline importieren
Import-GPO -BackupGpoName "MSFT Windows Server 2025 - Domain Controller" `
    -TargetName $GPOName `
    -Path $BackupPath

# GPO verknüpfen
New-GPLink -Name $GPOName -Target "OU=Domain Controllers,DC=secureops,DC=local"
```

### 3.5 Microsoft Learn Referenzen

- [Windows Security Baselines](https://learn.microsoft.com/de-de/windows/security/operating-system-security/device-management/windows-security-configuration-framework/windows-security-baselines)
- [Microsoft Security Compliance Toolkit](https://learn.microsoft.com/de-de/windows/security/operating-system-security/device-management/windows-security-configuration-framework/security-compliance-toolkit-10)
- [Konfigurieren von Sicherheitsrichtlinien](https://learn.microsoft.com/de-de/windows/security/operating-system-security/device-management/security-policy-settings/how-to-configure-security-policy-settings)

---

## 4. Jump Server Härtung

### 4.1 Credential Guard aktivieren

```powershell
# Virtualization Based Security (VBS) aktivieren
# Schützt Credentials im isolierten Container

# Hyper-V Feature für VBS erforderlich
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Hypervisor -All -NoRestart

# Credential Guard per Registry aktivieren
$path = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"
New-Item -Path $path -Force
Set-ItemProperty -Path $path -Name "EnableVirtualizationBasedSecurity" -Value 1
Set-ItemProperty -Path $path -Name "RequirePlatformSecurityFeatures" -Value 1

$lsaCfg = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
Set-ItemProperty -Path $lsaCfg -Name "LsaCfgFlags" -Value 1

# Neustart erforderlich!
```

### 4.2 AppLocker konfigurieren

```powershell
# AppLocker-Dienst aktivieren
Set-Service -Name AppIDSvc -StartupType Automatic
Start-Service -Name AppIDSvc

# Basis-AppLocker-Regeln erstellen
# Nur signierte Anwendungen + Windows-Verzeichnisse erlauben

$AppLockerPolicy = @'
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="AuditOnly">
    <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20" 
                  Name="(Default) All files located in the Windows folder" 
                  Description="Allow members of the Everyone group to run applications in Windows."
                  UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\*"/>
      </Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51"
                  Name="(Default) All files located in Program Files"
                  Description="Allow members of the Everyone group to run applications in Program Files."
                  UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES%\*"/>
      </Conditions>
    </FilePathRule>
  </RuleCollection>
</AppLockerPolicy>
'@

$AppLockerPolicy | Out-File -FilePath "$env:TEMP\AppLockerPolicy.xml"
Set-AppLockerPolicy -XmlPolicy "$env:TEMP\AppLockerPolicy.xml" -Merge
```

### 4.3 Sicherheitsreferenzen

- **CVE-2017-8563:** [NTLM SSO Authentication Vulnerability](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2017-8563)
- **CVE-2021-36934:** [Windows SAM/SYSTEM Hive Elevation](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2021-36934) (HiveNightmare)

---

## 5. Windows Admin Center

### 5.1 Installation auf Jump Server

```powershell
# Windows Admin Center (WAC) herunterladen
# https://www.microsoft.com/en-us/evalcenter/download-windows-admin-center

# Silent Installation
$WACInstaller = "C:\Temp\WindowsAdminCenter.msi"
$Port = 443
$CertThumbprint = (Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like "*Jump*" }).Thumbprint

msiexec /i $WACInstaller /qn /L*v "C:\Temp\WAC_Install.log" `
    SME_PORT=$Port `
    SSL_CERTIFICATE_OPTION=installed `
    SME_THUMBPRINT=$CertThumbprint
```

### 5.2 WAC für Server-Verwaltung konfigurieren

```powershell
# Remote-Server zu WAC hinzufügen
# CredSSP für WAC aktivieren (auf verwalteten Servern)

Enable-WSManCredSSP -Role Server -Force

# Auf Jump Server (Client)
Enable-WSManCredSSP -Role Client -DelegateComputer "*.secureops.local" -Force
```

### 5.3 Microsoft Learn Referenzen

- [Windows Admin Center Overview](https://learn.microsoft.com/de-de/windows-server/manage/windows-admin-center/overview)
- [WAC Installation](https://learn.microsoft.com/de-de/windows-server/manage/windows-admin-center/deploy/install)

---

## 6. Logging und Überwachung

### 6.1 Erweiterte Audit-Richtlinien

```powershell
# Erweiterte Audit-Richtlinien aktivieren
# Diese sind besonders wichtig für Jump Server

# Anmeldeversuche protokollieren
auditpol /set /subcategory:"Anmelden" /success:enable /failure:enable
auditpol /set /subcategory:"Abmelden" /success:enable
auditpol /set /subcategory:"Kontosperrung" /failure:enable

# Privilegierte Operationen
auditpol /set /subcategory:"Sensible Verwendung von Rechten" /success:enable /failure:enable

# PowerShell Script Block Logging
$PSLogging = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
New-Item -Path $PSLogging -Force
Set-ItemProperty -Path $PSLogging -Name "EnableScriptBlockLogging" -Value 1

# PowerShell Module Logging
$PSModuleLogging = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging"
New-Item -Path $PSModuleLogging -Force
Set-ItemProperty -Path $PSModuleLogging -Name "EnableModuleLogging" -Value 1
```

### 6.2 Log-Weiterleitung konfigurieren

```powershell
# Windows Event Forwarding (WEF) aktivieren
wecutil qc /q

# Event Collector Service starten
Set-Service -Name "Wecsvc" -StartupType Automatic
Start-Service -Name "Wecsvc"
```

---

## 7. BSI IT-Grundschutz Anforderungen

### 7.1 Relevante Bausteine für Jump Server

| Baustein | Anforderung | Umsetzung |
|----------|-------------|-----------|
| SYS.1.2.2.A6 | Sichere Authentisierung und Autorisierung | Kerberos, NLA, MFA |
| SYS.1.2.2.A9 | Lokale Kommunikationsfilterung | Windows Firewall |
| SYS.1.2.2.A11 | Angriffserkennung | Audit-Policies, SIEM |
| SYS.1.2.2.A20 | Schutz vor versteckten Administratorkonten | Account Auditing |

### 7.2 BSI-Empfehlungen umsetzen

```powershell
# BSI SYS.1.2.2.A7: Deaktivierung und Absicherung nicht benötigter Dienste
# Automatische Dienst-Analyse
$nonEssentialServices = Get-Service | Where-Object {
    $_.StartType -eq 'Automatic' -and
    $_.Status -eq 'Running' -and
    $_.Name -notin @('WinRM', 'W32Time', 'EventLog', 'CryptSvc', 'Netlogon', 'LanmanServer', 'LanmanWorkstation')
}
$nonEssentialServices | Format-Table Name, DisplayName, Status

# BSI SYS.1.2.2.A14: Herunterfahren verschlüsselter Daten bei geplantem Herunterfahren
# BitLocker für Jump Server empfohlen
Enable-BitLocker -MountPoint "C:" -EncryptionMethod XtsAes256 -UsedSpaceOnly -RecoveryPasswordProtector
```

---

## 8. Übungen Tag 2

### Übung 2.1: Jump Server Installation
1. Installieren Sie Windows Server 2025 Core als Jump Server
2. Konfigurieren Sie zwei Netzwerkadapter (Management + Server-Netz)
3. Installieren Sie RSAT-Tools

### Übung 2.2: Security Baseline anwenden
1. Laden Sie die Microsoft Security Baseline herunter
2. Wenden Sie die Baseline mit LGPO an
3. Überprüfen Sie die angewandten Einstellungen mit `gpresult`

### Übung 2.3: Credential Guard
1. Aktivieren Sie Credential Guard auf dem Jump Server
2. Starten Sie den Server neu
3. Überprüfen Sie den Status mit `systeminfo | findstr /i "Device Guard"`

### Übung 2.4: Windows Admin Center
1. Installieren Sie Windows Admin Center
2. Fügen Sie die Domain Controller hinzu
3. Testen Sie die Remote-Verwaltung

---

## 9. Zusammenfassung

✅ Jump Server sind der einzige Zugangspunkt für privilegierte Administration  
✅ Security Baselines von Microsoft liefern bewährte Sicherheitseinstellungen  
✅ Credential Guard schützt vor Pass-the-Hash-Angriffen  
✅ AppLocker verhindert Ausführung nicht autorisierter Software  
✅ Umfassendes Logging ist für Forensik und Compliance unerlässlich  

---

## Nächster Tag

➡️ [Tag 3: Admin Domain und Tier-Modell](Tag3-Admin-Domain.md)
