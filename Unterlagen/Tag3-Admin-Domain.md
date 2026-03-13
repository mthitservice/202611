# Tag 3: Admin Domain - ESAE-Architektur, Tier-Modell und AGDLP

## Lernziele

Nach Abschluss dieses Moduls können die Teilnehmer:
- Das Enhanced Security Admin Environment (ESAE) verstehen und planen
- Eine separate Admin-Domäne für größere Umgebungen einrichten
- Das Tier-Modell für privilegierten Zugriff implementieren
- Das AGDLP-Prinzip für Berechtigungsmanagement anwenden

---

## 1. Admin Forest Konzept (ESAE)

### 1.1 Was ist ESAE?

**Enhanced Security Administrative Environment (ESAE)** ist eine von Microsoft entwickelte Architektur zur Isolierung privilegierter Konten in einem separaten Forest.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         ESAE-Architektur                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────────┐         ┌─────────────────────┐               │
│  │   ADMIN FOREST      │ Trust   │   PRODUCTION FOREST │               │
│  │   (Red Forest)      │◄───────►│   (secureops.local) │               │
│  │                     │         │                     │               │
│  │  ├─ Tier 0 Admins   │         │  ├─ Domain Users    │               │
│  │  ├─ Tier 1 Admins   │         │  ├─ Domain Computers│               │
│  │  └─ Service Accounts│         │  └─ Applications    │               │
│  │                     │         │                     │               │
│  │  admin.secureops.   │         │  secureops.local    │               │
│  │  local              │         │                     │               │
│  └─────────────────────┘         └─────────────────────┘               │
│           │                                                             │
│           ▼                                                             │
│  ┌─────────────────────┐                                               │
│  │  Privileged Access  │   ⚡ Nur One-Way Trust                        │
│  │  Workstations (PAW) │   ⚡ Admin Forest vertraut Production         │
│  └─────────────────────┘   ⚡ Production vertraut Admin NICHT          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Wann Admin Forest verwenden?

| Umgebungsgröße | Empfehlung |
|----------------|------------|
| < 500 Benutzer | Tier-Modell in einer Domäne |
| 500 - 5.000 Benutzer | Tier-Modell + dedizierte OUs |
| > 5.000 Benutzer | Separater Admin Forest (ESAE) |
| Regulierte Branchen (Banken, Behörden) | Immer ESAE empfohlen |

### 1.3 Microsoft Learn Referenzen

- [Securing Privileged Access](https://learn.microsoft.com/de-de/security/privileged-access-workstations/overview)
- [Active Directory Administrative Tier Model](https://learn.microsoft.com/de-de/security/privileged-access-workstations/privileged-access-access-model)
- [Enterprise Access Model](https://learn.microsoft.com/de-de/security/privileged-access-workstations/privileged-access-access-model)

---

## 2. Das Tier-Modell

### 2.1 Tier-Übersicht

```
┌─────────────────────────────────────────────────────────────────┐
│                         TIER-MODELL                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  TIER 0 - Domain Admins & Infrastruktur                        │
│  ═══════════════════════════════════════                        │
│  • Domain Controllers                                           │
│  • AD Administrative Accounts                                   │
│  • PKI (Certificate Authorities)                                │
│  • Forest/Domain Trust Management                               │
│                                                                 │
│  ────────────────────────────────────────────────────────────  │
│                         ⬇️ Kann verwalten                        │
│  ────────────────────────────────────────────────────────────  │
│                                                                 │
│  TIER 1 - Server & Anwendungen                                  │
│  ════════════════════════════════                               │
│  • Member Server                                                │
│  • Application Server (SQL, Exchange, etc.)                     │
│  • Server Admins                                                │
│  • Service Accounts für Anwendungen                             │
│                                                                 │
│  ────────────────────────────────────────────────────────────  │
│                         ⬇️ Kann verwalten                        │
│  ────────────────────────────────────────────────────────────  │
│                                                                 │
│  TIER 2 - Workstations & Benutzer                               │
│  ════════════════════════════════════                           │
│  • Client Workstations                                          │
│  • Mobile Devices                                               │
│  • End User Accounts                                            │
│  • Helpdesk Admins                                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

⛔ KRITISCHE REGEL: Credentials dürfen NIEMALS von einem höheren 
   Tier auf einem niedrigeren Tier verwendet werden!
```

### 2.2 Tier-Verletzungen erkennen

| Verletzung | Risiko | Beispiel |
|------------|--------|----------|
| Tier 0 → Tier 2 Login | Kritisch | Domain Admin meldet sich an Workstation an |
| Tier 1 → Tier 2 Login | Hoch | Server Admin verwendet Workstation |
| Tier 0 Service auf Tier 1 | Kritisch | DC-Service-Account läuft auf Member Server |

### 2.3 OU-Struktur für Tier-Modell

```powershell
# Tier-basierte OU-Struktur erstellen
$Domain = "DC=secureops,DC=local"

# Tier 0
$Tier0OUs = @(
    "OU=Tier 0,$Domain",
    "OU=Accounts,OU=Tier 0,$Domain",
    "OU=Groups,OU=Tier 0,$Domain",
    "OU=Service Accounts,OU=Tier 0,$Domain",
    "OU=Servers,OU=Tier 0,$Domain"
)

# Tier 1
$Tier1OUs = @(
    "OU=Tier 1,$Domain",
    "OU=Accounts,OU=Tier 1,$Domain",
    "OU=Groups,OU=Tier 1,$Domain",
    "OU=Service Accounts,OU=Tier 1,$Domain",
    "OU=Servers,OU=Tier 1,$Domain"
)

# Tier 2
$Tier2OUs = @(
    "OU=Tier 2,$Domain",
    "OU=Accounts,OU=Tier 2,$Domain",
    "OU=Groups,OU=Tier 2,$Domain",
    "OU=Workstations,OU=Tier 2,$Domain",
    "OU=Users,OU=Tier 2,$Domain"
)

# OUs erstellen
foreach ($ou in ($Tier0OUs + $Tier1OUs + $Tier2OUs)) {
    try {
        New-ADOrganizationalUnit -Name ($ou -split ',')[0].Replace('OU=','') `
            -Path ($ou -replace '^OU=[^,]+,','') `
            -ProtectedFromAccidentalDeletion $true
        Write-Host "Erstellt: $ou" -ForegroundColor Green
    }
    catch {
        Write-Host "Existiert bereits: $ou" -ForegroundColor Yellow
    }
}
```

---

## 3. Admin Forest Installation

### 3.1 Vorbereitung

```powershell
# Admin Forest - Neuen Forest erstellen
# Server muss frisch installiert sein!

# AD DS Feature installieren
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Admin Forest promoten
$SafeModePassword = ConvertTo-SecureString "AdminF0rest!" -AsPlainText -Force

Install-ADDSForest `
    -DomainName "admin.secureops.local" `
    -DomainNetbiosName "ADMIN" `
    -ForestMode "WinThreshold" `
    -DomainMode "WinThreshold" `
    -DatabasePath "D:\NTDS" `
    -LogPath "E:\NTDS" `
    -SysvolPath "F:\SYSVOL" `
    -InstallDns `
    -SafeModeAdministratorPassword $SafeModePassword `
    -Force
```

### 3.2 One-Way Trust konfigurieren

```powershell
# Auf Admin Forest DC ausführen
# Admin Forest vertraut dem Production Forest (eingehend)
# Production Forest vertraut dem Admin Forest NICHT

$ProductionDomain = "secureops.local"
$AdminDomain = "admin.secureops.local"
$TrustPassword = "TrustP@ssw0rd!"

# Forest Trust erstellen (One-Way: Admin trust Production)
# Ausgehende Vertrauensstellung vom Admin Forest
netdom trust $AdminDomain /d:$ProductionDomain /add /twoway:no /oneside:trusted /passwordt:$TrustPassword
```

### 3.3 Admin-Gruppen konfigurieren

```powershell
# Im Admin Forest - Tier 0 Admin Gruppen erstellen
$Tier0Groups = @(
    @{Name = "T0-DomainAdmins"; Description = "Tier 0 - Domain Administration"},
    @{Name = "T0-EnterpriseAdmins"; Description = "Tier 0 - Enterprise Administration"},
    @{Name = "T0-SchemaAdmins"; Description = "Tier 0 - Schema Administration"},
    @{Name = "T0-DCAdmins"; Description = "Tier 0 - Domain Controller Administration"}
)

foreach ($group in $Tier0Groups) {
    New-ADGroup -Name $group.Name `
        -GroupScope Universal `
        -GroupCategory Security `
        -Description $group.Description `
        -Path "OU=Groups,OU=Tier 0,DC=admin,DC=secureops,DC=local"
}
```

---

## 4. Das AGDLP-Prinzip

### 4.1 Was ist AGDLP?

**AGDLP** steht für:
- **A**ccounts (Benutzerkonten)
- **G**lobal Groups (Globale Gruppen)
- **D**omain **L**ocal Groups (Lokale Domänengruppen)
- **P**ermissions (Berechtigungen)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           AGDLP-PRINZIP                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────┐    ┌──────────────┐    ┌────────────────┐    ┌────────┐  │
│  │ ACCOUNTS │───▶│GLOBAL GROUPS │───▶│ DOMAIN LOCAL   │───▶│RESOURCE│  │
│  │          │    │              │    │ GROUPS         │    │        │  │
│  │ Max      │    │ GG_IT_Admins │    │ DL_FileShare_  │    │Ordner  │  │
│  │ Lisa     │    │ GG_HR_Staff  │    │ Read           │    │Drucker │  │
│  │ Tom      │    │              │    │ DL_Printer_    │    │Server  │  │
│  │          │    │              │    │ Print          │    │        │  │
│  └──────────┘    └──────────────┘    └────────────────┘    └────────┘  │
│                                                                         │
│  Begründung:                                                            │
│  • Globale Gruppen: Organisationseinheiten (Abteilungen, Rollen)        │
│  • Domain Local: Ressourcenzugriff (Was darf getan werden?)            │
│  • Einfache Änderungen: User → GG | GG → DL | DL → Ressource           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 AGDLP mit AGUDLP erweitern

In Multi-Domain-Umgebungen wird **AGUDLP** verwendet:
- **U**niversal Groups (für Forest-weite Gruppierungen)

```
Accounts → Global Groups → Universal Groups → Domain Local Groups → Permissions
```

### 4.3 AGDLP-Struktur implementieren

```powershell
# Beispiel: Fileserver-Berechtigungen mit AGDLP

# 1. Global Groups für Abteilungen (A → G)
$GlobalGroups = @(
    @{Name = "GG_IT_Department"; Description = "IT-Abteilung Mitarbeiter"},
    @{Name = "GG_HR_Department"; Description = "HR-Abteilung Mitarbeiter"},
    @{Name = "GG_Finance_Department"; Description = "Finanz-Abteilung Mitarbeiter"}
)

foreach ($gg in $GlobalGroups) {
    New-ADGroup -Name $gg.Name `
        -GroupScope Global `
        -GroupCategory Security `
        -Description $gg.Description `
        -Path "OU=Groups,OU=Tier 2,DC=secureops,DC=local"
}

# 2. Domain Local Groups für Ressourcen (G → DL)
$DomainLocalGroups = @(
    @{Name = "DL_FinanceShare_Read"; Description = "Lesezugriff Finance Share"},
    @{Name = "DL_FinanceShare_Modify"; Description = "Änderungszugriff Finance Share"},
    @{Name = "DL_FinanceShare_FullControl"; Description = "Vollzugriff Finance Share"}
)

foreach ($dl in $DomainLocalGroups) {
    New-ADGroup -Name $dl.Name `
        -GroupScope DomainLocal `
        -GroupCategory Security `
        -Description $dl.Description `
        -Path "OU=Groups,OU=Tier 1,DC=secureops,DC=local"
}

# 3. Globale Gruppen in Domain Local einfügen (G → DL)
Add-ADGroupMember -Identity "DL_FinanceShare_Read" -Members "GG_HR_Department"
Add-ADGroupMember -Identity "DL_FinanceShare_Modify" -Members "GG_Finance_Department"
Add-ADGroupMember -Identity "DL_FinanceShare_FullControl" -Members "GG_IT_Department"

# 4. Berechtigungen auf Ressource setzen (DL → P)
$SharePath = "E:\Shares\Finance"
$Acl = Get-Acl $SharePath

# Read
$ReadRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "SECUREOPS\DL_FinanceShare_Read",
    "ReadAndExecute",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)
$Acl.AddAccessRule($ReadRule)

# Modify
$ModifyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "SECUREOPS\DL_FinanceShare_Modify",
    "Modify",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)
$Acl.AddAccessRule($ModifyRule)

# Full Control
$FullRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "SECUREOPS\DL_FinanceShare_FullControl",
    "FullControl",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)
$Acl.AddAccessRule($FullRule)

Set-Acl -Path $SharePath -AclObject $Acl
```

### 4.4 Microsoft Learn Referenzen

- [Bewährte Methoden für Gruppenrichtlinien](https://learn.microsoft.com/de-de/windows-server/identity/ad-ds/plan/security-best-practices/implementing-least-privilege-administrative-models)
- [AD DS-Sicherheit: Bewährte Methoden](https://learn.microsoft.com/de-de/windows-server/identity/ad-ds/plan/security-best-practices/best-practices-for-securing-active-directory)
- [Delegierung der Active Directory-Administration](https://learn.microsoft.com/de-de/windows-server/identity/ad-ds/plan/delegating-administration-by-using-ou-objects)

---

## 5. Protected Users und Authentication Policies

### 5.1 Protected Users Gruppe

```powershell
# Tier 0 Konten zur Protected Users Gruppe hinzufügen
$Tier0Accounts = Get-ADUser -Filter * -SearchBase "OU=Accounts,OU=Tier 0,DC=secureops,DC=local"

foreach ($account in $Tier0Accounts) {
    Add-ADGroupMember -Identity "Protected Users" -Members $account
    Write-Host "Hinzugefügt zu Protected Users: $($account.SamAccountName)" -ForegroundColor Green
}
```

### 5.2 Authentication Policy Silos

```powershell
# Authentication Policy für Tier 0 erstellen
New-ADAuthenticationPolicy -Name "Tier0-AuthPolicy" `
    -Description "Authentication Policy für Tier 0 Konten" `
    -UserTGTLifetimeMins 240 `
    -ProtectedFromAccidentalDeletion $true `
    -Enforce

# Authentication Policy Silo erstellen
New-ADAuthenticationPolicySilo -Name "Tier0-Silo" `
    -Description "Silo für Tier 0 Konten und Computer" `
    -UserAuthenticationPolicy "Tier0-AuthPolicy" `
    -ComputerAuthenticationPolicy "Tier0-AuthPolicy" `
    -ServiceAuthenticationPolicy "Tier0-AuthPolicy" `
    -ProtectedFromAccidentalDeletion $true `
    -Enforce

# Konten zum Silo hinzufügen
$Tier0Accounts | ForEach-Object {
    Set-ADAccountAuthenticationPolicySilo -Identity $_ -AuthenticationPolicySilo "Tier0-Silo"
}
```

---

## 6. Server Installation in der neuen Umgebung

### 6.1 Server Core mit Domänenbeitritt

```powershell
# Server Core - Netzwerk konfigurieren
$IP = "10.0.0.50"
$Prefix = 24
$Gateway = "10.0.0.1"
$DNS = @("10.0.0.1", "10.0.0.2")

New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress $IP -PrefixLength $Prefix -DefaultGateway $Gateway
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses $DNS

# Computer umbenennen
Rename-Computer -NewName "SRV-APP01" -Force

# Domäne beitreten - in die richtige OU!
$Credential = Get-Credential -Message "Domain Admin Credentials"
Add-Computer -DomainName "secureops.local" `
    -OUPath "OU=Servers,OU=Tier 1,DC=secureops,DC=local" `
    -Credential $Credential `
    -Restart
```

### 6.2 Server in Tier-OUs organisieren

```powershell
# Server-Klassifizierung
$ServerClassification = @{
    'SRV-DC01' = 'OU=Servers,OU=Tier 0,DC=secureops,DC=local'
    'SRV-DC02' = 'OU=Servers,OU=Tier 0,DC=secureops,DC=local'
    'SRV-CA01' = 'OU=Servers,OU=Tier 0,DC=secureops,DC=local'
    'SRV-SQL01' = 'OU=Servers,OU=Tier 1,DC=secureops,DC=local'
    'SRV-APP01' = 'OU=Servers,OU=Tier 1,DC=secureops,DC=local'
    'SRV-FILE01' = 'OU=Servers,OU=Tier 1,DC=secureops,DC=local'
}

foreach ($server in $ServerClassification.GetEnumerator()) {
    $computer = Get-ADComputer -Identity $server.Key -ErrorAction SilentlyContinue
    if ($computer) {
        Move-ADObject -Identity $computer.DistinguishedName -TargetPath $server.Value
        Write-Host "Server $($server.Key) verschoben nach $($server.Value)" -ForegroundColor Green
    }
}
```

---

## 7. Sicherheitsreferenzen

### 7.1 CVE-Relevante Schwachstellen

| CVE | Name | Risiko | Mitigation |
|-----|------|--------|------------|
| CVE-2020-1472 | Zerologon | Kritisch | August 2020 Patch + Enforcement Mode |
| CVE-2021-42278 | sAMAccountName Spoofing | Hoch | November 2021 Patch |
| CVE-2021-42287 | Kerberos PAC Issues | Hoch | November 2021 Patch |
| CVE-2022-26923 | AD Certificate Services | Kritisch | Mai 2022 Patch |

### 7.2 BSI IT-Grundschutz

| Baustein | Anforderung |
|----------|-------------|
| APP.2.2.A2 | Planung des Active Directory |
| APP.2.2.A5 | Delegation von Rechten |
| APP.2.2.A9 | Protokollierung |
| APP.2.2.A16 | Verwendung von administrativen Konten trennen |

---

## 8. Übungen Tag 3

### Übung 3.1: Tier-OU-Struktur erstellen
1. Erstellen Sie die komplette OU-Struktur für Tier 0, 1 und 2
2. Erstellen Sie GPOs pro Tier mit Sicherheitseinstellungen
3. Verknüpfen Sie die GPOs mit den entsprechenden OUs

### Übung 3.2: AGDLP implementieren
1. Erstellen Sie globale Gruppen für 3 Abteilungen
2. Erstellen Sie Domain Local Gruppen für einen Fileserver
3. Konfigurieren Sie die Gruppenverschachtelung
4. Setzen Sie NTFS-Berechtigungen auf einen Testordner

### Übung 3.3: Admin-Konten erstellen
1. Erstellen Sie Tier 0, Tier 1 und Tier 2 Admin-Konten
2. Fügen Sie Tier 0 Konten zur Protected Users Gruppe hinzu
3. Erstellen Sie eine Authentication Policy für Tier 0

### Übung 3.4: Server hinzufügen
1. Installieren Sie einen neuen Server Core
2. Fügen Sie ihn der Domäne hinzu (in richtige OU!)
3. Konfigurieren Sie die Firewall für die Serverrolle

---

## 9. Zusammenfassung

✅ Admin Forests (ESAE) isolieren privilegierte Konten vom Production Forest  
✅ Das Tier-Modell verhindert laterale Bewegung von Angreifern  
✅ AGDLP sorgt für konsistentes und wartbares Berechtigungsmanagement  
✅ Protected Users und Authentication Policies schützen kritische Konten  
✅ Server müssen in die richtige Tier-OU eingeordnet werden  

---

## Nächster Tag

➡️ [Tag 4: PowerShell Security - JEA und DSC](Tag4-PowerShell-Security.md)
