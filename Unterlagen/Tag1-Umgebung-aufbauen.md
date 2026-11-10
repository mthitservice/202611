# Tag 1: Umgebung aufbauen - Sichere Windows Server 2025 Installation

## Lernziele

Nach Abschluss dieses Moduls können die Teilnehmer:
- Windows Server 2025 Core Edition sicher installieren
- Separate Laufwerke für Datenbank-Dateien (Daten und Logs) konfigurieren
- Nicht benötigte Netzwerkdienste identifizieren und deaktivieren
- Grundlegende Härtungsmaßnahmen anwenden

---

## 1. Windows Server 2025 Editionen

### 1.1 Core Edition vs. Desktop Experience

| Aspekt | Core Edition | Desktop Experience |
|--------|-------------|-------------------|
| Angriffsfläche | Minimal | Größer |
| Ressourcenverbrauch | ~4 GB RAM | ~8 GB RAM |
| Verwaltung | Remote (RSAT, WAC, PowerShell) | Lokal oder Remote |
| Empfehlung für Produktion | ✅ Bevorzugt | Nur wenn GUI zwingend erforderlich |

> **Best Practice:** Verwenden Sie immer die Core Edition, es sei denn, eine Anwendung erfordert explizit die GUI.

### 1.2 Microsoft Learn Referenzen

- [Übersicht über die Windows Server-Installationsoptionen](https://learn.microsoft.com/de-de/windows-server/get-started/install-options-server-core-desktop-experience)
- [Verwalten von Server Core](https://learn.microsoft.com/de-de/windows-server/administration/server-core/server-core-manage)

---

## 2. Festplattenpartitionierung für Datenbanken

### 2.1 Wichtigkeit der Trennung

Bei der Installation von Verzeichnisdiensten wie **Active Directory** oder **DNS** müssen die Datenbankdateien auf **separaten Laufwerken** gespeichert werden:

| Dateityp | Standardpfad | Empfohlener Pfad | Begründung |
|----------|-------------|------------------|------------|
| AD-Datenbank (NTDS.dit) | C:\Windows\NTDS | D:\NTDS\Data | Performance, Wiederherstellung |
| AD-Logs | C:\Windows\NTDS | E:\NTDS\Logs | I/O-Trennung, Backup |
| SYSVOL | C:\Windows\SYSVOL | F:\SYSVOL | Replikation, Größenwachstum |
| DNS-Datenbank | C:\Windows\System32\dns | D:\DNS\Data | Bei dateibasiertem DNS |

### 2.2 Warum separate Laufwerke?

1. **Performance:** Parallele I/O-Operationen auf verschiedenen Festplatten
2. **Wiederherstellung:** Bei Datenbankkorruption können Logs zur Reparatur verwendet werden
3. **Kapazitätsplanung:** Unabhängiges Wachstum der Volumes
4. **Backup:** Granulare Sicherungsstrategien möglich

### 2.3 PowerShell-Beispiel: Laufwerkskonfiguration

```powershell
# Laufwerke für AD-Installation vorbereiten
$disks = @{
    'NTDS_Data' = 'D:'
    'NTDS_Logs' = 'E:'
    'SYSVOL'    = 'F:'
}

foreach ($disk in $disks.GetEnumerator()) {
    $path = Join-Path $disk.Value $disk.Key
    if (-not (Test-Path $path)) {
        New-Item -Path $path -ItemType Directory -Force
        Write-Host "Verzeichnis erstellt: $path" -ForegroundColor Green
    }
}
```

### 2.4 AD DS Installation mit separaten Pfaden

```powershell
# AD DS-Rolle installieren
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Domäne promoten mit separaten Laufwerken
Install-ADDSForest `
    -DomainName "secureops.local" `
    -DomainNetbiosName "SECUREOPS" `
    -DatabasePath "D:\NTDS" `
    -LogPath "E:\NTDS" `
    -SysvolPath "F:\SYSVOL" `
    -InstallDns `
    -SafeModeAdministratorPassword (ConvertTo-SecureString "P@ssw0rd!" -AsPlainText -Force) `
    -Force
```

### 2.5 Microsoft Learn Referenzen

- [Installieren von Active Directory Domain Services](https://learn.microsoft.com/de-de/windows-server/identity/ad-ds/deploy/install-active-directory-domain-services--level-100-)
- [AD DS-Bereitstellung: Bewährte Methoden](https://learn.microsoft.com/de-de/windows-server/identity/ad-ds/plan/ad-ds-design-and-planning)

---

## 3. Netzwerkdienste deaktivieren

### 3.1 Prinzip der minimalen Angriffsfläche

Jeder laufende Dienst erhöht die Angriffsfläche des Servers. Deaktivieren Sie alle nicht benötigten Dienste.

### 3.2 Häufig nicht benötigte Dienste

```powershell
# Liste häufig nicht benötigter Dienste
$ServicesToDisable = @(
    'Browser',           # Computer Browser
    'lltdsvc',          # Link-Layer Topology Discovery
    'SSDPSRV',          # SSDP Discovery (UPnP)
    'upnphost',         # UPnP Device Host
    'WMPNetworkSvc',    # Windows Media Player Network Sharing
    'XblAuthManager',   # Xbox Live Auth Manager
    'XblGameSave',      # Xbox Live Game Save
    'WSearch',          # Windows Search (auf Servern meist nicht nötig)
    'RemoteRegistry'    # Remote Registry
)

foreach ($service in $ServicesToDisable) {
    $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
    if ($svc) {
        Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
        Set-Service -Name $service -StartupType Disabled
        Write-Host "Dienst deaktiviert: $service" -ForegroundColor Yellow
    }
}
```

### 3.3 Netzwerkprotokolle prüfen

```powershell
# Nicht benötigte Netzwerkbindungen entfernen
# SMBv1 deaktivieren (kritische Sicherheitslücke - CVE-2017-0144 WannaCry)
Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart

# IPv6 deaktivieren (falls nicht verwendet)
# Achtung: Nur deaktivieren wenn wirklich nicht benötigt!
Get-NetAdapterBinding -ComponentID ms_tcpip6 | 
    Disable-NetAdapterBinding -ComponentID ms_tcpip6

# NetBIOS über TCP/IP deaktivieren
$adapters = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled }
foreach ($adapter in $adapters) {
    $adapter.SetTcpipNetbios(2) # 2 = Disable
}
```

### 3.4 Sicherheitsreferenzen

- **CVE-2017-0144:** [EternalBlue/WannaCry - SMBv1 Vulnerability](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2017-0144)
- **BSI:** [IT-Grundschutz-Baustein SYS.1.2.3: Windows Server (Edition 2023)](https://www.bsi.bund.de/SharedDocs/Downloads/DE/BSI/Grundschutz/IT-GS-Kompendium_Einzel_PDFs_2023/07_SYS_IT_Systeme/SYS_1_2_3_Windows_Server_Edition_2023.pdf?__blob=publicationFile&v=5) – SYS.1.2.2 gilt in der Edition 2023 nur noch für Windows Server 2012; [Prüfstatus der BSI-Links](Referenzen.md#deutsche-sicherheitsressourcen-bsi).

---

## 4. Firewall-Konfiguration

### 4.1 Grundregel: Deny All, Allow Specific

```powershell
# Windows Firewall aktivieren für alle Profile
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True

# Standardverhalten: Eingehend blockieren, ausgehend erlauben
Set-NetFirewallProfile -Profile Domain,Public,Private `
    -DefaultInboundAction Block `
    -DefaultOutboundAction Allow

# Alle bestehenden Regeln anzeigen
Get-NetFirewallRule | Where-Object { $_.Enabled -eq 'True' } | 
    Select-Object DisplayName, Direction, Action, Profile
```

### 4.2 Nur notwendige Ports öffnen

```powershell
# Beispiel: Nur AD-relevante Ports für Domain Controller
$ADPorts = @(
    @{Name='DNS-TCP'; Port=53; Protocol='TCP'},
    @{Name='DNS-UDP'; Port=53; Protocol='UDP'},
    @{Name='Kerberos-TCP'; Port=88; Protocol='TCP'},
    @{Name='Kerberos-UDP'; Port=88; Protocol='UDP'},
    @{Name='LDAP-TCP'; Port=389; Protocol='TCP'},
    @{Name='LDAP-UDP'; Port=389; Protocol='UDP'},
    @{Name='LDAPS'; Port=636; Protocol='TCP'},
    @{Name='AD-Global-Catalog'; Port=3268; Protocol='TCP'},
    @{Name='AD-Global-Catalog-SSL'; Port=3269; Protocol='TCP'}
)

foreach ($rule in $ADPorts) {
    New-NetFirewallRule `
        -DisplayName "AD - $($rule.Name)" `
        -Direction Inbound `
        -Protocol $rule.Protocol `
        -LocalPort $rule.Port `
        -Action Allow `
        -Profile Domain
}
```

---

## 5. BSI IT-Grundschutz Anforderungen

### 5.1 Relevante Bausteine

| Baustein | Beschreibung | Link |
|----------|--------------|------|
| SYS.1.1 | Allgemeiner Server | [BSI SYS.1.1 (PDF)](https://www.bsi.bund.de/SharedDocs/Downloads/DE/BSI/Grundschutz/IT-GS-Kompendium_Einzel_PDFs_2023/07_SYS_IT_Systeme/SYS_1_1_Allgemeiner_Server_Edition_2023.pdf?__blob=publicationFile&v=3) |
| SYS.1.2.3 | Windows Server | [BSI SYS.1.2.3 (PDF)](https://www.bsi.bund.de/SharedDocs/Downloads/DE/BSI/Grundschutz/IT-GS-Kompendium_Einzel_PDFs_2023/07_SYS_IT_Systeme/SYS_1_2_3_Windows_Server_Edition_2023.pdf?__blob=publicationFile&v=5) |
| APP.2.2 | Active Directory Domain Services | [BSI APP.2.2 (PDF)](https://www.bsi.bund.de/SharedDocs/Downloads/DE/BSI/Grundschutz/IT-GS-Kompendium_Einzel_PDFs_2023/06_APP_Anwendungen/APP_2_2_Active_Directory_Domain_Services_Edition_2023.pdf?__blob=publicationFile&v=4) |

### 5.2 Basis-Anforderungen (MUSS)

1. **SYS.1.2.3.A1:** Planung von Windows Server
2. **SYS.1.2.3.A2:** Sichere Installation von Windows Server
3. **SYS.1.2.3.A3:** Telemetrie- und Nutzungsdaten unter Windows Server

Standard-Anforderung (SOLLTE): **SYS.1.2.3.A4:** Schutz vor Ausnutzung von Schwachstellen in Anwendungen.

```powershell
# Telemetrie deaktivieren (BSI SYS.1.2.3.A3)
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" `
    -Name "AllowTelemetry" -Value 0 -Type DWord

# Dienst deaktivieren
Set-Service -Name "DiagTrack" -StartupType Disabled
Stop-Service -Name "DiagTrack" -Force
```

---

## 6. CVE-Datenbank und Schwachstellenmanagement

### 6.1 Wichtige Ressourcen

| Ressource | Beschreibung | URL |
|-----------|--------------|-----|
| CVE (MITRE) | Internationale CVE-Datenbank | https://cve.mitre.org |
| NVD | National Vulnerability Database | https://nvd.nist.gov |
| ENISA | EU Agency for Cybersecurity | https://www.enisa.europa.eu |
| CERT-EU | Computer Emergency Response Team EU | https://cert.europa.eu |
| BSI CERT-Bund | Deutsches CERT | https://www.bsi.bund.de/DE/Themen/Unternehmen-und-Organisationen/Cyber-Sicherheitslage/Reaktion/CERT-Bund/cert-bund_node.html |
| CERT-Bund WID | Warn- und Informationsdienst | https://wid.cert-bund.de/portal/wid/shortinfo |

### 6.2 Patch-Management

```powershell
# Windows Update konfigurieren für Server (nur Sicherheitsupdates)
$WUSettings = (New-Object -ComObject Microsoft.Update.AutoUpdate)
$WUSettings.EnableService()

# Installierte Updates prüfen
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10
```

---

## 7. Übungen Tag 1

### Übung 1.1: Server Core Installation
1. Installieren Sie Windows Server 2025 Core Edition
2. Konfigurieren Sie die Netzwerkeinstellungen mit `sconfig`
3. Verbinden Sie sich remote per PowerShell

### Übung 1.2: Laufwerksvorbereitung
1. Erstellen Sie drei virtuelle Festplatten (NTDS, Logs, SYSVOL)
2. Initialisieren und formatieren Sie die Laufwerke
3. Erstellen Sie die Verzeichnisstruktur

### Übung 1.3: AD DS Installation
1. Installieren Sie AD DS mit den vorbereiteten Laufwerken
2. Verifizieren Sie, dass die Dateien korrekt verteilt sind
3. Überprüfen Sie die Event Logs auf Fehler

### Übung 1.4: Dienste-Härtung
1. Identifizieren Sie nicht benötigte Dienste
2. Deaktivieren Sie SMBv1
3. Konfigurieren Sie die Windows Firewall

---

## 8. Zusammenfassung

✅ Windows Server 2025 Core Edition ist die bevorzugte Installationsoption  
✅ AD-Datenbanken gehören auf separate Laufwerke (Daten und Logs getrennt)  
✅ Nicht benötigte Dienste und Protokolle müssen deaktiviert werden  
✅ Die Firewall muss nach dem Prinzip "Deny All, Allow Specific" konfiguriert werden  
✅ BSI IT-Grundschutz und CVE-Datenbanken sind wichtige Referenzen  

---

## Nächster Tag

➡️ [Tag 2: Jump Server Installation](Tag2-Jump-Server.md)
