# Referenzen und Ressourcen

## Microsoft Windows 2025 Server SecureOps

Dieses Dokument enthält alle wichtigen Referenzen, Links und Ressourcen für den Kurs.

---

## Microsoft Learn Pfade

### Windows Server Administration

| Thema | Link |
|-------|------|
| Windows Server-Installationsoptionen | https://learn.microsoft.com/de-de/windows-server/get-started/install-options-server-core-desktop-experience |
| Server Core Administration | https://learn.microsoft.com/de-de/windows-server/administration/server-core/server-core-manage |
| Windows Admin Center | https://learn.microsoft.com/de-de/windows-server/manage/windows-admin-center/overview |
| Windows Server Security | https://learn.microsoft.com/de-de/windows-server/security/security-and-assurance |

### Active Directory

| Thema | Link |
|-------|------|
| AD DS Installation | https://learn.microsoft.com/de-de/windows-server/identity/ad-ds/deploy/install-active-directory-domain-services--level-100- |
| AD DS Design & Planning | https://learn.microsoft.com/de-de/windows-server/identity/ad-ds/plan/ad-ds-design-and-planning |
| AD Security Best Practices | https://learn.microsoft.com/de-de/windows-server/identity/ad-ds/plan/security-best-practices/best-practices-for-securing-active-directory |
| Least Privilege Admin Models | https://learn.microsoft.com/de-de/windows-server/identity/ad-ds/plan/security-best-practices/implementing-least-privilege-administrative-models |

### Privileged Access

| Thema | Link |
|-------|------|
| Privileged Access Workstations | https://learn.microsoft.com/de-de/security/privileged-access-workstations/privileged-access-workstations |
| Enterprise Access Model | https://learn.microsoft.com/de-de/security/privileged-access-workstations/privileged-access-access-model |
| Securing Privileged Access | https://learn.microsoft.com/de-de/security/privileged-access-workstations/overview |
| Tier Model | https://learn.microsoft.com/de-de/security/privileged-access-workstations/privileged-access-access-model |

### Security Baselines

| Thema | Link |
|-------|------|
| Windows Security Baselines | https://learn.microsoft.com/de-de/windows/security/operating-system-security/device-management/windows-security-configuration-framework/windows-security-baselines |
| Security Compliance Toolkit | https://learn.microsoft.com/de-de/windows/security/operating-system-security/device-management/windows-security-configuration-framework/security-compliance-toolkit-10 |
| Security Policy Settings | https://learn.microsoft.com/de-de/windows/security/operating-system-security/device-management/security-policy-settings/how-to-configure-security-policy-settings |

### PowerShell Security

| Thema | Link |
|-------|------|
| PowerShell Security Features | https://learn.microsoft.com/de-de/powershell/scripting/learn/security-features |
| About Signing | https://learn.microsoft.com/de-de/powershell/module/microsoft.powershell.core/about/about_signing |
| Just Enough Administration | https://learn.microsoft.com/de-de/powershell/scripting/learn/remoting/jea/overview |
| JEA Role Capabilities | https://learn.microsoft.com/de-de/powershell/scripting/learn/remoting/jea/role-capabilities |
| JEA Session Configurations | https://learn.microsoft.com/de-de/powershell/scripting/learn/remoting/jea/session-configurations |

### Desired State Configuration

| Thema | Link |
|-------|------|
| DSC Overview | https://learn.microsoft.com/de-de/powershell/dsc/overview |
| DSC Configurations | https://learn.microsoft.com/de-de/powershell/dsc/configurations/configurations |
| DSC Resources | https://learn.microsoft.com/de-de/powershell/dsc/resources/resources |
| DSC Getting Started | https://learn.microsoft.com/de-de/powershell/dsc/getting-started/wingettingstarted |

---

## Sicherheits-Datenbanken

### CVE - Common Vulnerabilities and Exposures

| Ressource | Beschreibung | Link |
|-----------|--------------|------|
| MITRE CVE | Internationale CVE-Datenbank | https://cve.mitre.org |
| CVE Details | Detailsuche für CVEs | https://www.cvedetails.com |
| NVD | National Vulnerability Database (USA) | https://nvd.nist.gov |

### Europäische Sicherheitsressourcen

| Ressource | Beschreibung | Link |
|-----------|--------------|------|
| ENISA | European Union Agency for Cybersecurity | https://www.enisa.europa.eu |
| CERT-EU | Computer Emergency Response Team EU | https://cert.europa.eu |
| EU CVE Database | EU Vulnerability Database | https://www.enisa.europa.eu/topics/threat-risk-management/vulnerabilities |

### Deutsche Sicherheitsressourcen (BSI)

| Ressource | Beschreibung | Link |
|-----------|--------------|------|
| BSI | Bundesamt für Sicherheit in der Informationstechnik | https://www.bsi.bund.de |
| IT-Grundschutz Kompendium | Umfassende Sicherheitsstandards | https://www.bsi.bund.de/DE/Themen/Unternehmen-und-Organisationen/Standards-und-Zertifizierung/IT-Grundschutz/IT-Grundschutz-Kompendium/it-grundschutz-kompendium_node.html |
| IT-Grundschutz Bausteine | Download einzelner Bausteine | https://www.bsi.bund.de/DE/Themen/Unternehmen-und-Organisationen/Standards-und-Zertifizierung/IT-Grundschutz/IT-Grundschutz-Kompendium/IT-Grundschutz-Bausteine/Bausteine_Download_Edition_node.html |
| CERT-Bund | Deutsches CERT | https://www.bsi.bund.de/CERT-Bund |
| Warn- und Informationsdienst | Aktuelle Sicherheitswarnungen | https://www.bsi.bund.de/DE/Themen/Unternehmen-und-Organisationen/Cyber-Sicherheitslage/Technische-Sicherheitshinweise-und-Warnungen/technische-sicherheitshinweise-und-warnungen_node.html |

---

## BSI IT-Grundschutz Bausteine (Server-relevant)

### Systembausteine

| Baustein | Titel | Beschreibung |
|----------|-------|--------------|
| SYS.1.1 | Allgemeiner Server | Grundlegende Serverabsicherung |
| SYS.1.2.2 | Windows Server | Spezifische Windows Server-Härtung |
| SYS.1.3 | Server unter Linux und Unix | Alternative OS-Absicherung |
| SYS.1.5 | Virtualisierung | VM-Sicherheit |
| SYS.1.6 | Containerisierung | Container-Sicherheit |
| SYS.1.8 | Speicherlösungen | Storage-Sicherheit |

### Anwendungsbausteine

| Baustein | Titel | Beschreibung |
|----------|-------|--------------|
| APP.2.2 | Active Directory Domain Services | AD-Absicherung |
| APP.3.6 | DNS-Server | DNS-Sicherheit |
| APP.5.3 | Allgemeiner E-Mail-Client und -Server | Mail-Sicherheit |

### Netzbausteine

| Baustein | Titel | Beschreibung |
|----------|-------|--------------|
| NET.1.1 | Netzarchitektur und -design | Netzwerksegmentierung |
| NET.3.1 | Router und Switches | Netzwerkgeräte-Sicherheit |
| NET.3.2 | Firewall | Firewall-Konfiguration |

---

## Wichtige CVEs für Windows Server

### Kritische Schwachstellen

| CVE | Name | Risiko | Beschreibung |
|-----|------|--------|--------------|
| CVE-2017-0144 | EternalBlue/WannaCry | Kritisch | SMBv1 Remote Code Execution |
| CVE-2020-1472 | Zerologon | Kritisch | Netlogon Privilege Escalation |
| CVE-2021-34527 | PrintNightmare | Kritisch | Print Spooler Remote Code Execution |
| CVE-2021-42278 | sAMAccountName Spoofing | Hoch | AD Account Name Bypasses |
| CVE-2021-42287 | noPac | Hoch | Kerberos PAC Vulnerabilities |
| CVE-2022-26923 | Certifried | Kritisch | AD Certificate Services Escalation |
| CVE-2022-37958 | SPNEGO | Hoch | NTLM Remote Code Execution |
| CVE-2017-8563 | NTLM SSO | Hoch | NTLM Authentication Relay |

### Mitigationen

```powershell
# Zerologon (CVE-2020-1472) - Enforcement aktivieren
reg add "HKLM\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" /v FullSecureChannelProtection /t REG_DWORD /d 1 /f

# PrintNightmare (CVE-2021-34527) - Spooler deaktivieren wenn nicht benötigt
Stop-Service -Name Spooler -Force
Set-Service -Name Spooler -StartupType Disabled

# SMBv1 (CVE-2017-0144) - Deaktivieren
Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart
```

---

## Downloads

### Microsoft Tools

| Tool | Beschreibung | Link |
|------|--------------|------|
| Security Compliance Toolkit | Security Baselines | https://www.microsoft.com/en-us/download/details.aspx?id=55319 |
| Windows Admin Center | Zentrale Verwaltung | https://www.microsoft.com/de-de/windows-server/windows-admin-center |
| LAPS | Local Admin Password Solution | https://www.microsoft.com/en-us/download/details.aspx?id=46899 |
| Microsoft Defender for Identity | AD-Bedrohungserkennung | https://learn.microsoft.com/de-de/defender-for-identity/ |

### PowerShell Module

```powershell
# Wichtige DSC-Module installieren
Install-Module -Name SecurityPolicyDsc -Force
Install-Module -Name AuditPolicyDsc -Force
Install-Module -Name xPSDesiredStateConfiguration -Force
Install-Module -Name NetworkingDsc -Force
Install-Module -Name ComputerManagementDsc -Force
```

---

## Checklisten

### Server-Installation Checkliste

- [ ] Core Edition verwenden (wenn möglich)
- [ ] Separate Laufwerke für AD-Datenbank und Logs
- [ ] Hostname und IP-Adresse konfigurieren
- [ ] Windows Update durchführen
- [ ] SMBv1 deaktivieren
- [ ] Nicht benötigte Dienste deaktivieren
- [ ] Windows Firewall aktivieren und konfigurieren
- [ ] Telemetrie deaktivieren
- [ ] Remote-Management einrichten

### Domain Controller Checkliste

- [ ] AD-Datenbank auf separatem Laufwerk
- [ ] AD-Logs auf separatem Laufwerk
- [ ] SYSVOL auf separatem Laufwerk
- [ ] DNS-Server installieren
- [ ] Zeitserver konfigurieren
- [ ] Replikation testen
- [ ] FSMO-Rollen dokumentieren

### Jump Server Checkliste

- [ ] Netzwerktrennung (Management + Server-Netz)
- [ ] Security Baseline anwenden
- [ ] Credential Guard aktivieren
- [ ] AppLocker konfigurieren
- [ ] Windows Admin Center installieren
- [ ] Audit-Policies aktivieren
- [ ] BitLocker aktivieren

### PowerShell Security Checkliste

- [ ] Execution Policy auf AllSigned
- [ ] Code Signing Zertifikat bereitstellen
- [ ] JEA-Endpoints konfigurieren
- [ ] Transcription aktivieren
- [ ] Script Block Logging aktivieren
- [ ] Module Logging aktivieren

---

## Kontakt

**Trainer:** Michael Lindner

Bei Fragen zum Kursmaterial wenden Sie sich bitte an Ihren Trainer.

---

*Letzte Aktualisierung: März 2026*
