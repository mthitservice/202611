# Tag 5: JIT-Administration – Hyper-V-Failover-Cluster mit Storage Spaces Direct vom Jump Server

## Lernziele

Nach diesem Tag können die Teilnehmer:

- Just-in-Time-Administration (JIT) mit zeitlich begrenzter AD-Gruppenmitgliedschaft (PAM-Feature, TTL) umsetzen
- einen Cluster-Administrator ohne dauerhafte Rechte vorbereiten (Tier 1, Protected Users, AGDLP)
- Cluster Name Object (CNO) und Witness vorab bereitstellen, damit der Admin keine AD-Erstellrechte benötigt
- einen Windows-Server-2025-Failover-Cluster mit Hyper-V und Storage Spaces Direct (S2D) **vollständig per PowerShell vom Jump Server** aufbauen
- Netzwerk (Switch Embedded Teaming), Validierung, CSV, Live Migration und Abnahme skriptgesteuert prüfen
- Rechte nach Abschluss automatisch verfallen lassen bzw. vorzeitig entziehen

---

## 1. Szenario und Architektur

```text
                         secureops.local
 ┌──────────────────────────────────────────────────────────────────────┐
 │  Tier 0: SRV-DC01 (PAM-Feature, TTL-Mitgliedschaften, Audit 4728/4729)│
 └──────────────────────────────────────────────────────────────────────┘
        ▲ LDAP/Kerberos                       ▲ Freigabe (Vier Augen)
        │                                      │
 ┌──────┴───────────────┐   WinRM / RPC   ┌───┴───────────────────────┐
 │ SRV-JS01 (Jump Server)│ ─────────────► │ SRV-HV01      SRV-HV02     │
 │ t1-adm-hvcluster      │   Kerberos     │  MGMT  10.0.0.61/.62       │
 │ RSAT, Skripte modul05 │   kein CredSSP │  SET1+SET2 = SETswitch     │
 └───────────────────────┘                │   ├ vEthernet (SMB1) 10.10.1.x
                                          │   └ vEthernet (SMB2) 10.10.2.x
                                          │  4 Datenplatten je Knoten  │
                                          │  ── S2D-Pool, CSVFS_ReFS ──│
                                          │  Cluster SRV-HVCL01 .60    │
                                          └────────────┬───────────────┘
                                                       │ SMB 3 (verschlüsselt)
                                          ┌────────────┴───────────────┐
                                          │ SRV-FILE01: File Share Witness│
                                          └────────────────────────────┘
```

| Komponente | Wert (Lab) | Hinweis |
|------------|-----------|---------|
| Knoten | `SRV-HV01`, `SRV-HV02` | Windows Server 2025 **Datacenter** (S2D-Voraussetzung), Server Core |
| Cluster | `SRV-HVCL01`, `10.0.0.60` | CNO vorab in `OU=HV-Cluster,OU=Servers,OU=Tier 1` |
| Netze | Management `10.0.0.0/24`, SMB1 `10.10.1.0/24`, SMB2 `10.10.2.0/24` | SMB-Netze ohne Gateway und ohne DNS-Registrierung |
| Witness | `\\SRV-FILE01\HVCL01-Witness$` | Zugriff ausschließlich für `SRV-HVCL01$` |
| Volumes | `CSV01`, `CSV02` je 100 GB | Two-Way-Mirror, ReFS |

Alle Parameter stehen zentral in [ClusterConfig.psd1](../Powershell/modul05/ClusterConfig.psd1). Namen, IP-Adressen und OUs **nur dort** anpassen.

### 1.1 Tier-Einordnung

Hyper-V-Hosts sind mindestens **Tier 1**. Laufen auf dem Cluster Domain Controller, CA oder andere Tier-0-Systeme, ist der **gesamte Cluster inklusive Speicher, Backup und Verwaltung Tier 0** – dann gelten die Tier-0-Konten, -OUs und -Jump-Server aus Tag 3. Wer die Hosts verwaltet, kontrolliert alle Gäste (Zugriff auf VHDX, Arbeitsspeicher, Konsole).

### 1.2 Rollen und Verantwortlichkeiten

| Rolle | Konto/Gruppe | Schritte | Rechte |
|-------|--------------|----------|--------|
| Lab-Administrator | lokal am Hypervisor | 0 | nur Lab |
| Jump-Server-Admin | Tier-1-Admin | 1 | lokal Admin auf SRV-JS01 |
| Enterprise Admin (befristet) | Tier 0 | 2 | einmalig, danach entfernen |
| AD-Administrator | delegiert auf Tier-1-OU | 3, 4 | OU, Gruppen, Konten |
| Server-Administrator | Tier 1 | 5 | lokal Admin auf den neuen Knoten |
| Fileserver-Administrator | Tier 1 | 6 | lokal Admin auf SRV-FILE01 |
| Freigeber | `T1-JIT-Approvers` | 7, 8 | **nur** Schreibrecht auf `member` der JIT-Gruppe |
| **Cluster-Admin** | `t1-adm-hvcluster` | 10–19 | **nur während JIT**: lokal Admin auf Knoten + Vollzugriff auf CNO |

> **Prinzip:** Kein Konto besitzt dauerhaft alle Rechte. Der Cluster-Admin erhält Rechte nur für die Dauer des Auftrags, die Vergabe erfolgt durch eine zweite Person, und die Rechte verfallen **automatisch**.

---

## 2. JIT-Konzept in Active Directory

### 2.1 Zeitlich begrenzte Gruppenmitgliedschaft (PAM-Feature)

Ab Gesamtstrukturfunktionsebene Windows Server 2016 kann das optionale Feature **Privileged Access Management** aktiviert werden. Danach akzeptiert `Add-ADGroupMember` den Parameter `-MemberTimeToLive`:

- Die Mitgliedschaft wird als **dynamischer Link mit TTL** gespeichert und vom DC nach Ablauf automatisch entfernt.
- Der KDC begrenzt die Laufzeit von TGT und Service-Tickets auf die **kürzeste Restlaufzeit** aller TTL-Mitgliedschaften des Kontos. Nach Ablauf kann der Admin also keine neuen Tickets mit der Gruppe mehr erhalten.
- Die Restlaufzeit ist mit `Get-ADGroup -Properties member -ShowMemberTimeToLive` sichtbar (`<TTL=Sekunden>,CN=…`).
- Die Aktivierung ist **nicht umkehrbar**.

### 2.2 Gruppenmodell nach AGDLP (Tag 3)

```text
t1-adm-hvcluster ──(TTL 4h)──► T1-HVCluster-Admins-JIT (Global)
                                    │
                                    ▼
                          DL-HVCluster-LocalAdmins (Domain Local)
                                    │
                 ┌──────────────────┼────────────────────────┐
                 ▼                                           ▼
   lokale Administratoren SRV-HV01/02          GenericAll auf CNO SRV-HVCL01
```

| Gruppe | Bereich | Zweck | Dauerhafte Mitglieder |
|--------|---------|-------|------------------------|
| `T1-HVCluster-Admins-JIT` | Global | Rollen-/JIT-Gruppe | **keine** |
| `DL-HVCluster-LocalAdmins` | Domain Local | Ressourcenrechte | nur die JIT-Gruppe |
| `T1-JIT-Approvers` | Global | Freigeber (nur `member` schreiben) | benannte Personen |

### 2.3 Warum alles vom Jump Server?

- **Kein Double Hop:** `Test-Cluster`, `New-Cluster`, `Enable-ClusterStorageSpacesDirect` und `Add-ClusterVirtualMachineRole` laufen direkt vom Jump Server gegen die Knoten. Befehle, die auf einem Knoten andere Knoten oder Freigaben ansprechen müssten, werden vermieden – dadurch ist **keine Kerberos-Delegation und kein CredSSP** nötig.
- **Protected Users** funktioniert deshalb uneingeschränkt (nur Kerberos/AES, keine Delegation, TGT max. 4 h).
- Alle Aktionen landen im PowerShell-Transkript und Script Block Logging des Jump Servers (Tag 2/4).

### 2.4 Abgrenzung

| Verfahren | Einsatz |
|-----------|---------|
| PAM-TTL (dieser Tag) | Bordmittel, AD-intern, ideal für befristete Projektrechte |
| JEA (Tag 4) | dauerhafte, eng begrenzte Routineaufgaben (z. B. Knoten pausieren) |
| MIM PAM / Bastion Forest mit Shadow Principals | ESAE-Szenario mit Admin-Forest (Tag 3) |
| Entra PIM / Azure Arc | hybride Umgebungen mit Genehmigungs-Workflow |

---

## 3. Voraussetzungen

- Domäne `secureops.local`, Tier-OU-Struktur aus Tag 3, Gesamtstrukturfunktionsebene **≥ Windows Server 2016**.
- Jump Server aus Tag 2 (`SRV-JS01`), Gruppe `T1-JumpServer-Users` für die Anmeldung, PowerShell-Transkription und Script Block Logging aktiv.
- Zwei Knoten mit **Windows Server 2025 Datacenter** (Core), in der Domäne, je ein Management-Adapter und zwei Adapter für SET, mindestens zwei leere Datenplatten pro Knoten.
- Fileserver `SRV-FILE01` (Tier 1) für den Witness – alternativ Cloud Witness.
- Firewall (Tag 1, „deny all“): vom Jump Server zu den Knoten WinRM (TCP 5985), RPC (TCP 135 + dynamisch), SMB (TCP 445); zwischen den Knoten Cluster-Kommunikation (UDP/TCP 3343) und SMB 445. Die Failover-Clustering-Rolle aktiviert ihre Regeln selbst; die SMB-Regel setzt Schritt 12.
- Skripte gemäß Tag 4 **signieren**, falls `AllSigned` erzwungen ist:

```powershell
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object Subject -like '*SecureOps*'
Get-ChildItem .\Powershell\modul05\*.ps1 | Set-AuthenticodeSignature -Certificate $cert `
    -TimestampServer 'http://timestamp.digicert.com' -HashAlgorithm SHA256
```

---

## 4. Skriptübersicht

Alle Skripte liegen in [Powershell/modul05](../Powershell/modul05/) und werden – bis auf Schritt 0 – **auf dem Jump Server** in einer erhöhten Windows PowerShell 5.1 ausgeführt. Sie sind idempotent (erneuter Aufruf ändert nichts Vorhandenes) und unterstützen, wo sinnvoll, `-WhatIf`.

| Schritt | Skript | Wer | Wirkung |
|---------|--------|-----|---------|
| – | [ClusterConfig.psd1](../Powershell/modul05/ClusterConfig.psd1) | alle | zentrale Parameter |
| – | [Cluster.Common.ps1](../Powershell/modul05/Cluster.Common.ps1) | alle | TTL-Auswertung der JIT-Gruppe |
| 0 | [00-Lab-New-ClusterNodeVMs.ps1](../Powershell/modul05/00-Lab-New-ClusterNodeVMs.ps1) | Lab-Admin | Nested-VMs als Knoten (nur Lab) |
| 1 | [01-Install-JumpServerTools.ps1](../Powershell/modul05/01-Install-JumpServerTools.ps1) | Jump-Server-Admin | RSAT AD, Cluster, Hyper-V |
| 2 | [02-Enable-AdPamFeature.ps1](../Powershell/modul05/02-Enable-AdPamFeature.ps1) | Enterprise Admin (befristet) | PAM-Feature aktivieren |
| 3 | [03-New-ClusterAdDelegation.ps1](../Powershell/modul05/03-New-ClusterAdDelegation.ps1) | AD-Admin | OU, Gruppen, CNO, Delegation |
| 4 | [04-New-ClusterAdminAccount.ps1](../Powershell/modul05/04-New-ClusterAdminAccount.ps1) | AD-Admin | Konto ohne Dauerrechte |
| 5 | [05-Set-NodeLocalAdmins.ps1](../Powershell/modul05/05-Set-NodeLocalAdmins.ps1) | Server-Admin | DL-Gruppe → lokale Admins |
| 6 | [06-New-FileShareWitness.ps1](../Powershell/modul05/06-New-FileShareWitness.ps1) | Fileserver-Admin | Witness-Freigabe für CNO |
| 7 | [07-Grant-ClusterAdminJit.ps1](../Powershell/modul05/07-Grant-ClusterAdminJit.ps1) | Freigeber | JIT mit TTL erteilen |
| 8 | [08-Revoke-ClusterAdminJit.ps1](../Powershell/modul05/08-Revoke-ClusterAdminJit.ps1) | Freigeber | JIT vorzeitig entziehen |
| 10 | [10-Test-JitAccessAndPrereqs.ps1](../Powershell/modul05/10-Test-JitAccessAndPrereqs.ps1) | Cluster-Admin | JIT + Voraussetzungen prüfen |
| 11 | [11-Install-NodeRoles.ps1](../Powershell/modul05/11-Install-NodeRoles.ps1) | Cluster-Admin | Hyper-V, Clustering, Neustarts |
| 12 | [12-Set-NodeNetworking.ps1](../Powershell/modul05/12-Set-NodeNetworking.ps1) | Cluster-Admin | SET-Switch, SMB-vNICs |
| 13 | [13-Clear-S2DDisks.ps1](../Powershell/modul05/13-Clear-S2DDisks.ps1) | Cluster-Admin | Datenplatten leeren (**destruktiv**) |
| 14 | [14-Test-ClusterReadiness.ps1](../Powershell/modul05/14-Test-ClusterReadiness.ps1) | Cluster-Admin | SMB-Test, Test-Cluster |
| 15 | [15-New-HvCluster.ps1](../Powershell/modul05/15-New-HvCluster.ps1) | Cluster-Admin | Cluster, Netze, Witness |
| 16 | [16-Enable-S2D.ps1](../Powershell/modul05/16-Enable-S2D.ps1) | Cluster-Admin | S2D, CSV-Volumes |
| 17 | [17-Set-HyperVClusterSettings.ps1](../Powershell/modul05/17-Set-HyperVClusterSettings.ps1) | Cluster-Admin | VM-Pfade, Live Migration |
| 18 | [18-New-ClusterTestVm.ps1](../Powershell/modul05/18-New-ClusterTestVm.ps1) | Cluster-Admin | HA-Test-VM, Live Migration |
| 19 | [19-Test-ClusterHealth.ps1](../Powershell/modul05/19-Test-ClusterHealth.ps1) | Cluster-Admin / Betrieb | Abnahme |

---

## 5. Phase A – Lab-Knoten bereitstellen (nur Lab)

### Schritt 0: Knoten als verschachtelte VMs anlegen

**Wo:** physischer Lab-Hyper-V-Host · **Wer:** Lab-Administrator

Nested Virtualization benötigt statischen Arbeitsspeicher, `ExposeVirtualizationExtensions` und MAC-Spoofing (für Gast-vSwitch/SET). Über **Device Naming** sieht der Gast die Adapternamen `MGMT`, `SET1`, `SET2`; Schritt 12 benennt die Adapter im Gast danach automatisch um. Die SET-Adapter hängen an einem privaten Storage-Switch.

```powershell
.\00-Lab-New-ClusterNodeVMs.ps1 -IsoPath D:\ISO\WS2025.iso -WhatIf
.\00-Lab-New-ClusterNodeVMs.ps1 -IsoPath D:\ISO\WS2025.iso
```

**Skript** [00-Lab-New-ClusterNodeVMs.ps1](../Powershell/modul05/00-Lab-New-ClusterNodeVMs.ps1):

```powershell
#requires -Version 5.1
#requires -RunAsAdministrator
#requires -Modules Hyper-V
<#
.SYNOPSIS
    Schritt 0 (nur Lab): Legt die Cluster-Knoten als verschachtelte Hyper-V-VMs an.
.DESCRIPTION
    Auf dem physischen Lab-Hyper-V-Host ausfuehren, NICHT auf dem Jump Server.
    Je Knoten: Gen2, statischer RAM, Nested Virtualization, vTPM, Netzadapter MGMT/SET1/SET2
    mit Device Naming, MAC-Spoofing fuer SET und leere Datenplatten fuer S2D.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Leaf })][string]$IsoPath,
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1",
    [string]$VmRoot = 'D:\Lab\VMs',
    [string]$ManagementSwitch = 'LabSwitch',
    [string]$StorageSwitch = 'LabStorage',
    [ValidateRange(6, 64)][int]$MemoryGB = 8,
    [ValidateRange(2, 8)][int]$DataDiskCount = 4,
    [ValidateRange(32, 1024)][int]$DataDiskGB = 100
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath

if (-not (Get-VMSwitch -Name $ManagementSwitch -ErrorAction SilentlyContinue)) {
    throw "Management-Switch '$ManagementSwitch' fehlt auf dem Lab-Host."
}
if (-not (Get-VMSwitch -Name $StorageSwitch -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($StorageSwitch, 'Privaten Storage-Switch anlegen')) {
        New-VMSwitch -Name $StorageSwitch -SwitchType Private | Out-Null
    }
}

foreach ($node in $cfg.Nodes) {
    $name = $node.Name
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
        Write-Warning "$name existiert bereits - uebersprungen."
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($name, 'Cluster-Knoten-VM anlegen')) { continue }

    $vmPath = Join-Path $VmRoot $name
    New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
    New-VM -Name $name -Generation 2 -Path $VmRoot -MemoryStartupBytes ($MemoryGB * 1GB) `
        -NewVHDPath (Join-Path $vmPath 'OS.vhdx') -NewVHDSizeBytes 80GB `
        -SwitchName $ManagementSwitch | Out-Null

    # Nested Virtualization erfordert statischen RAM und durchgereichte VT-x/AMD-V-Erweiterungen
    Set-VMMemory -VMName $name -DynamicMemoryEnabled $false
    Set-VMProcessor -VMName $name -Count 4 -ExposeVirtualizationExtensions $true
    Set-VMKeyProtector -VMName $name -NewLocalKeyProtector
    Enable-VMTPM -VMName $name
    Set-VM -Name $name -AutomaticCheckpointsEnabled $false

    Get-VMNetworkAdapter -VMName $name | Rename-VMNetworkAdapter -NewName $cfg.ManagementAdapter
    foreach ($adapter in $cfg.SetAdapters) {
        Add-VMNetworkAdapter -VMName $name -Name $adapter -SwitchName $StorageSwitch
    }
    # Device Naming: Gast sieht den Adapternamen; MAC-Spoofing fuer Nested-VMs/SET
    Get-VMNetworkAdapter -VMName $name | Set-VMNetworkAdapter -DeviceNaming On -MacAddressSpoofing On

    $dataPath = Join-Path $vmPath 'Data'
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
    for ($i = 1; $i -le $DataDiskCount; $i++) {
        $vhd = Join-Path $dataPath ("Data{0:D2}.vhdx" -f $i)
        New-VHD -Path $vhd -SizeBytes ($DataDiskGB * 1GB) -Dynamic | Out-Null
        Add-VMHardDiskDrive -VMName $name -ControllerType SCSI -Path $vhd
    }

    $dvd = Add-VMDvdDrive -VMName $name -Path $IsoPath -Passthru
    Set-VMFirmware -VMName $name -FirstBootDevice $dvd
    Write-Host "$name angelegt. Windows Server 2025 Datacenter (Core) installieren." -ForegroundColor Green
}
```

Danach je Knoten **Windows Server 2025 Datacenter (Core)** installieren, `MGMT` mit `10.0.0.61`/`.62` adressieren und gemäß Tag 3, Abschnitt 6.1 in die Domäne aufnehmen (OU-Verschiebung erledigt Schritt 3).

> Kapazität im Lab: 2 Knoten × 4 × 100 GB = 800 GB roh. Two-Way-Mirror verdoppelt den Platzbedarf, zusätzlich sollte je Knoten eine Platte als Reserve frei bleiben → 2 × 100 GB Volumes passen.

---

## 6. Phase B – Einmalige Vorbereitung (ohne den Cluster-Admin)

### Schritt 1: Verwaltungswerkzeuge auf dem Jump Server

**Wo:** SRV-JS01 · **Wer:** Jump-Server-Administrator

```powershell
.\01-Install-JumpServerTools.ps1
```

**Skript** [01-Install-JumpServerTools.ps1](../Powershell/modul05/01-Install-JumpServerTools.ps1):

```powershell
#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Schritt 1: Installiert die Verwaltungswerkzeuge auf dem Jump Server.
.DESCRIPTION
    Einmalig durch den Jump-Server-Administrator. Danach laufen alle Cluster-Schritte
    remote vom Jump Server; auf den Knoten wird nicht interaktiv gearbeitet.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -eq 1) {
    # Windows-Client-PAW: RSAT als Features on Demand
    foreach ($capability in @(
            'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
            'Rsat.FailoverCluster.Management.Tools~~~~0.0.1.0')) {
        if ((Get-WindowsCapability -Online -Name $capability).State -ne 'Installed') {
            Add-WindowsCapability -Online -Name $capability | Out-Null
        }
    }
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -NoRestart | Out-Null
}
else {
    Install-WindowsFeature -Name RSAT-AD-PowerShell, RSAT-Clustering-PowerShell, Hyper-V-PowerShell | Out-Null
}

foreach ($module in 'ActiveDirectory', 'FailoverClusters', 'Hyper-V', 'Storage') {
    if (-not (Get-Module -ListAvailable -Name $module)) { throw "Modul $module fehlt." }
    Write-Host "Modul verfuegbar: $module" -ForegroundColor Green
}
```

### Schritt 2: PAM-Feature aktivieren

**Wo:** SRV-JS01 · **Wer:** Enterprise Admin, nur für diesen Schritt (danach Mitgliedschaft entfernen)

```powershell
.\02-Enable-AdPamFeature.ps1 -WhatIf
.\02-Enable-AdPamFeature.ps1          # fragt wegen ConfirmImpact High nach
```

**Skript** [02-Enable-AdPamFeature.ps1](../Powershell/modul05/02-Enable-AdPamFeature.ps1):

```powershell
#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 2: Aktiviert das AD-Feature "Privileged Access Management" (zeitlich begrenzte Gruppenmitgliedschaft).
.DESCRIPTION
    Einmalig, als zeitlich begrenzter Enterprise Admin, vom Jump Server.
    Voraussetzung: Gesamtstrukturfunktionsebene mindestens Windows Server 2016.
    ACHTUNG: Die Aktivierung ist NICHT umkehrbar.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$dc = $cfg.DomainController

$forest = Get-ADForest -Server $dc
# ADForestMode: 7 = Windows2016Forest
if ([int]$forest.ForestMode -lt 7) {
    throw "Gesamtstrukturfunktionsebene $($forest.ForestMode) ist zu niedrig (mindestens Windows2016Forest)."
}

$feature = Get-ADOptionalFeature -Filter "Name -eq 'Privileged Access Management Feature'" -Server $dc
if ($feature.EnabledScopes.Count -gt 0) {
    Write-Host 'PAM-Feature ist bereits aktiviert.' -ForegroundColor Yellow
    return
}

if ($PSCmdlet.ShouldProcess($forest.Name, 'PAM-Feature dauerhaft aktivieren (nicht umkehrbar)')) {
    Enable-ADOptionalFeature -Identity $feature -Scope ForestOrConfigurationSet `
        -Target $forest.Name -Server $dc -Confirm:$false
    $feature = Get-ADOptionalFeature -Identity $feature -Server $dc
    if ($feature.EnabledScopes.Count -eq 0) { throw 'PAM-Feature wurde nicht aktiviert.' }
    Write-Host 'PAM-Feature aktiviert. Enterprise-Admin-Mitgliedschaft jetzt wieder entfernen.' -ForegroundColor Green
}
```

**Prüfen:**

```powershell
Get-ADOptionalFeature -Filter "Name -like 'Privileged*'" | Select-Object Name, EnabledScopes
```

### Schritt 3: AD vorbereiten – OU, Gruppen, CNO, Delegation

**Wo:** SRV-JS01 · **Wer:** AD-Administrator (Rechte auf `OU=Tier 1`)

Das Skript legt das **CNO deaktiviert vorab** an und gibt der Domain-Local-Gruppe Vollzugriff darauf. Damit kann `New-Cluster` (Schritt 15) das CNO übernehmen, ohne dass der Cluster-Admin Computerobjekte erstellen darf. Das CNO selbst erhält „Computerobjekte erstellen“ in der Cluster-OU, falls später Clusterrollen mit eigenem Namen (VCO) entstehen. Freigeber dürfen ausschließlich das Attribut `member` der JIT-Gruppe schreiben.

```powershell
.\03-New-ClusterAdDelegation.ps1
Add-ADGroupMember -Identity T1-JIT-Approvers -Members t1-adm-mueller, t1-adm-schmidt   # Beispiel
```

**Skript** [03-New-ClusterAdDelegation.ps1](../Powershell/modul05/03-New-ClusterAdDelegation.ps1):

```powershell
#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 3: AD-Struktur fuer den Cluster vorbereiten (OU, AGDLP-Gruppen, vorab erstelltes CNO, Delegation).
.DESCRIPTION
    Einmalig durch einen AD-Administrator mit Rechten auf der Tier-1-OU, vom Jump Server.
    - OU fuer Cluster-Knoten und CNO, Knoten werden dorthin verschoben
    - Global  T1-HVCluster-Admins-JIT  (nur zeitlich begrenzte Mitglieder)
    - DomainLocal DL-HVCluster-LocalAdmins (enthaelt die JIT-Gruppe)
    - Global  T1-JIT-Approvers (darf ausschliesslich 'member' der JIT-Gruppe schreiben)
    - CNO deaktiviert vorab anlegen; DL-Gruppe erhaelt Vollzugriff auf das CNO,
      das CNO darf in der Cluster-OU Computerobjekte (VCOs) anlegen.
    Der Cluster-Admin braucht damit KEINE Rechte zum Anlegen von Objekten in AD.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$dc = $cfg.DomainController
$clusterOu = "OU=$($cfg.ClusterOuName),$($cfg.Tier1ServersOu)"
$computerClassGuid = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2'
$memberAttributeGuid = [guid]'bf9679c0-0de6-11d0-a285-00aa003049e2'

if (-not (Get-PSDrive -Name SOAD -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name SOAD -PSProvider ActiveDirectory -Root '//RootDSE/' -Server $dc | Out-Null
}

function Get-OrNewGroup {
    param([string]$Name, [string]$Scope, [string]$Description)
    $group = Get-ADGroup -Filter "Name -eq '$Name'" -Server $dc
    if (-not $group) {
        $group = New-ADGroup -Name $Name -SamAccountName $Name -GroupScope $Scope -GroupCategory Security `
            -Path $cfg.GroupsOu -Description $Description -Server $dc -PassThru
        Set-ADObject -Identity $group -ProtectedFromAccidentalDeletion $true -Server $dc
        Write-Host "Gruppe angelegt: $Name ($Scope)" -ForegroundColor Green
    }
    $group
}

function Add-AdAccessRule {
    param([string]$DistinguishedName, [System.DirectoryServices.ActiveDirectoryAccessRule]$Rule)
    $path = "SOAD:\$DistinguishedName"
    $acl = Get-Acl -Path $path
    $existing = $acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object {
        $_.IdentityReference -eq $Rule.IdentityReference -and
        $_.ActiveDirectoryRights -eq $Rule.ActiveDirectoryRights -and
        $_.ObjectType -eq $Rule.ObjectType -and
        $_.AccessControlType -eq $Rule.AccessControlType
    }
    if ($existing) { return }
    $acl.AddAccessRule($Rule)
    Set-Acl -Path $path -AclObject $acl
    Write-Host "ACE gesetzt auf $DistinguishedName ($($Rule.ActiveDirectoryRights))" -ForegroundColor Green
}

# 1. OU
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$clusterOu'" -Server $dc)) {
    New-ADOrganizationalUnit -Name $cfg.ClusterOuName -Path $cfg.Tier1ServersOu `
        -ProtectedFromAccidentalDeletion $true -Server $dc
    Write-Host "OU angelegt: $clusterOu" -ForegroundColor Green
}

# 2. Gruppen nach AGDLP
$jitGroup = Get-OrNewGroup -Name $cfg.JitGroup -Scope Global `
    -Description 'JIT: Hyper-V-Cluster-Administration, nur Mitgliedschaft mit TTL'
$localAdminGroup = Get-OrNewGroup -Name $cfg.LocalAdminGroup -Scope DomainLocal `
    -Description 'Lokale Administratoren SRV-HV* und Vollzugriff auf das CNO'
$approverGroup = Get-OrNewGroup -Name $cfg.ApproverGroup -Scope Global `
    -Description 'Darf JIT-Mitgliedschaften fuer Tier-1-JIT-Gruppen vergeben'

if (-not (Get-ADGroupMember -Identity $localAdminGroup -Server $dc | Where-Object SID -eq $jitGroup.SID)) {
    Add-ADGroupMember -Identity $localAdminGroup -Members $jitGroup -Server $dc
    Write-Host "$($cfg.JitGroup) -> $($cfg.LocalAdminGroup)" -ForegroundColor Green
}

# 3. Knoten in die Cluster-OU verschieben
foreach ($node in $cfg.Nodes) {
    $computer = Get-ADComputer -Filter "Name -eq '$($node.Name)'" -Server $dc
    if (-not $computer) { Write-Warning "$($node.Name) ist noch nicht in der Domaene."; continue }
    if ($computer.DistinguishedName -notlike "*,$clusterOu") {
        Move-ADObject -Identity $computer -TargetPath $clusterOu -Server $dc
        Write-Host "$($node.Name) -> $clusterOu" -ForegroundColor Green
    }
}

# 4. CNO deaktiviert vorab anlegen (Prestaging)
$cno = Get-ADComputer -Filter "Name -eq '$($cfg.ClusterName)'" -Server $dc
if (-not $cno) {
    $cno = New-ADComputer -Name $cfg.ClusterName -Path $clusterOu -Enabled $false `
        -Description "Cluster Name Object $($cfg.ClusterName) (vorab angelegt)" -Server $dc -PassThru
    Set-ADObject -Identity $cno -ProtectedFromAccidentalDeletion $true -Server $dc
    Write-Host "CNO vorab angelegt (deaktiviert): $($cfg.ClusterName)" -ForegroundColor Green
}

# 5. Delegationen
Add-AdAccessRule -DistinguishedName $cno.DistinguishedName -Rule (
    New-Object System.DirectoryServices.ActiveDirectoryAccessRule($localAdminGroup.SID, 'GenericAll', 'Allow'))

Add-AdAccessRule -DistinguishedName $clusterOu -Rule (
    New-Object System.DirectoryServices.ActiveDirectoryAccessRule($cno.SID, 'ReadProperty', 'Allow'))
Add-AdAccessRule -DistinguishedName $clusterOu -Rule (
    New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $cno.SID, 'CreateChild', 'Allow', $computerClassGuid, 'None'))

Add-AdAccessRule -DistinguishedName $jitGroup.DistinguishedName -Rule (
    New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $approverGroup.SID, 'WriteProperty', 'Allow', $memberAttributeGuid, 'None'))

Write-Host "Fertig. Mitglieder fuer $($cfg.ApproverGroup) manuell und dauerhaft pflegen (Vier-Augen-Prinzip)." -ForegroundColor Cyan
```

**Prüfen:**

```powershell
Get-ADComputer SRV-HVCL01 -Properties Enabled, ProtectedFromAccidentalDeletion
(Get-Acl "AD:\$((Get-ADComputer SRV-HVCL01).DistinguishedName)").Access |
    Where-Object IdentityReference -like '*HVCluster*' | Select-Object IdentityReference, ActiveDirectoryRights
```

### Schritt 4: Cluster-Admin-Konto anlegen

**Wo:** SRV-JS01 · **Wer:** AD-Administrator

Persönliches Tier-1-Konto, **Protected Users**, „Konto ist vertraulich“, nur AES. Es darf sich am Jump Server anmelden, hat aber **keine** dauerhafte Gruppenmitgliedschaft mit Adminrechten – das Skript bricht ab, falls doch.

```powershell
.\04-New-ClusterAdminAccount.ps1 -GivenName Max -Surname Mustermann
```

**Skript** [04-New-ClusterAdminAccount.ps1](../Powershell/modul05/04-New-ClusterAdminAccount.ps1):

```powershell
#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 4: Persoenliches Tier-1-Adminkonto fuer den Cluster-Administrator anlegen.
.DESCRIPTION
    Einmalig durch einen AD-Administrator, vom Jump Server.
    Das Konto hat KEINE dauerhaften Adminrechte. Es darf sich nur am Jump Server anmelden;
    Rechte auf den Knoten entstehen ausschliesslich ueber die zeitlich begrenzte JIT-Mitgliedschaft.
    Protected Users: nur Kerberos/AES, keine Delegation, kein NTLM/CredSSP, TGT max. 4 Stunden.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GivenName,
    [Parameter(Mandatory)][string]$Surname,
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$dc = $cfg.DomainController
$sam = $cfg.ClusterAdminAccount

$user = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Server $dc
if (-not $user) {
    $password = Read-Host -AsSecureString "Initialkennwort fuer $sam (Uebergabe nur persoenlich)"
    $user = New-ADUser -Name "$sam ($GivenName $Surname)" -SamAccountName $sam `
        -UserPrincipalName "$sam@$($cfg.DomainFqdn)" -GivenName $GivenName -Surname $Surname `
        -Path $cfg.AccountsOu -AccountPassword $password -ChangePasswordAtLogon $true `
        -Enabled $true -AccountNotDelegated $true -KerberosEncryptionType AES128, AES256 `
        -Description 'Tier 1 Admin Hyper-V-Cluster - Rechte nur per JIT' -Server $dc -PassThru
    Write-Host "Konto angelegt: $sam" -ForegroundColor Green
}

# Protected Users = RID 525
$protectedUsers = Get-ADGroup -Identity "$((Get-ADDomain -Server $dc).DomainSID.Value)-525" -Server $dc
Add-ADGroupMember -Identity $protectedUsers -Members $user -Server $dc

if (Get-ADGroup -Filter "Name -eq '$($cfg.JumpServerUsersGroup)'" -Server $dc) {
    Add-ADGroupMember -Identity $cfg.JumpServerUsersGroup -Members $user -Server $dc
}
else {
    Write-Warning "Gruppe $($cfg.JumpServerUsersGroup) (Anmeldung am Jump Server, Tag 2) nicht gefunden."
}

# Sprachunabhaengig ueber SIDs: -512 Domain Admins, -519 Enterprise Admins, S-1-5-32-544 Administrators
$standing = Get-ADPrincipalGroupMembership -Identity $user -Server $dc | Where-Object {
    $_.Name -in $cfg.JitGroup, $cfg.LocalAdminGroup -or
    $_.SID.Value -match '-(512|519)$' -or $_.SID.Value -eq 'S-1-5-32-544'
}
if ($standing) {
    throw "Dauerhafte privilegierte Mitgliedschaft gefunden: $($standing.Name -join ', ')"
}
Write-Host "$sam ist vorbereitet und hat keine dauerhaften Adminrechte." -ForegroundColor Green
```

### Schritt 5: DL-Gruppe auf den Knoten berechtigen

**Wo:** SRV-JS01 · **Wer:** Tier-1-Server-Administrator (der die Knoten aufgenommen hat)

Die lokale Administratorgruppe wird sprachunabhängig über die SID `S-1-5-32-544` angesprochen. Produktiv per GPO auf die Cluster-OU (Restricted Groups / Gruppenrichtlinien-Einstellungen „Lokale Benutzer und Gruppen“).

```powershell
.\05-Set-NodeLocalAdmins.ps1
```

**Skript** [05-Set-NodeLocalAdmins.ps1](../Powershell/modul05/05-Set-NodeLocalAdmins.ps1):

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Schritt 5: DL-Gruppe in die lokalen Administratoren der Cluster-Knoten aufnehmen.
.DESCRIPTION
    Einmalig durch den Tier-1-Serveradministrator, der die Knoten in die Domaene aufgenommen hat.
    Produktiv besser per GPO (Restricted Groups / Gruppenrichtlinien-Einstellungen) auf die Cluster-OU.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$nodes = $cfg.Nodes | ForEach-Object { $_.Name }
$member = "$($cfg.DomainNetbios)\$($cfg.LocalAdminGroup)"

Invoke-Command -ComputerName $nodes -ScriptBlock {
    # S-1-5-32-544 = lokale Administratoren (sprachunabhaengig)
    $admins = Get-LocalGroup -SID 'S-1-5-32-544'
    if (-not (Get-LocalGroupMember -Group $admins | Where-Object Name -eq $using:member)) {
        Add-LocalGroupMember -Group $admins -Member $using:member
    }
    [pscustomobject]@{
        Node    = $env:COMPUTERNAME
        Members = (Get-LocalGroupMember -Group $admins).Name -join '; '
    }
} | Select-Object Node, Members | Format-Table -AutoSize -Wrap
```

### Schritt 6: File Share Witness vorbereiten

**Wo:** SRV-JS01 · **Wer:** Fileserver-Administrator

Da das CNO seit Schritt 3 existiert, kann die Freigabe schon jetzt **ausschließlich** für `SECUREOPS\SRV-HVCL01$` berechtigt werden; SMB-Verschlüsselung ist erzwungen.

```powershell
.\06-New-FileShareWitness.ps1
```

**Skript** [06-New-FileShareWitness.ps1](../Powershell/modul05/06-New-FileShareWitness.ps1):

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Schritt 6: File Share Witness auf dem Fileserver anlegen; Zugriff nur fuer das CNO.
.DESCRIPTION
    Einmalig durch den Fileserver-Administrator, vom Jump Server.
    Das CNO existiert durch Schritt 3 bereits (deaktiviert), daher kann es vorab berechtigt werden.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$cnoAccount = "$($cfg.DomainNetbios)\$($cfg.ClusterName)$"
$witnessPath = $cfg.WitnessPath
$witnessShare = $cfg.WitnessShare
$clusterName = $cfg.ClusterName

Invoke-Command -ComputerName $cfg.WitnessServer -ScriptBlock {
    $path = $using:witnessPath
    $share = $using:witnessShare
    New-Item -ItemType Directory -Path $path -Force | Out-Null

    # NTFS: Vererbung entfernen, nur SYSTEM, Administratoren und CNO
    & icacls.exe $path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "$($using:cnoAccount):(OI)(CI)M" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls fehlgeschlagen ($LASTEXITCODE)." }

    if (-not (Get-SmbShare -Name $share -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $share -Path $path -FullAccess $using:cnoAccount -EncryptData $true `
            -FolderEnumerationMode AccessBased -Description "Cluster Witness $($using:clusterName)" | Out-Null
    }
    Get-SmbShareAccess -Name $share | Select-Object Name, AccountName, AccessRight
}
```

> Alternative ohne eigenen Fileserver: **Cloud Witness** (`Set-ClusterQuorum -CloudWitness -AccountName … -AccessKey …`) – dann Schritt 6 entfällt und Schritt 15 entsprechend anpassen.

---

## 7. Phase C – JIT anfordern und gewähren

### Schritt 7: JIT-Berechtigung erteilen

**Wo:** SRV-JS01 · **Wer:** Freigeber (`T1-JIT-Approvers`), **nicht** der Antragsteller

Ablauf:

1. Der Cluster-Admin stellt einen Change/Antrag (z. B. `CHG-2026-1142`) mit Zeitfenster.
2. Der Freigeber prüft und erteilt die Mitgliedschaft mit TTL (Standard 4 h, max. 8 h laut Konfiguration).
3. Das Skript verhindert Selbstfreigabe, prüft auf (verbotene) dauerhafte Mitglieder und verifiziert die TTL.

```powershell
.\07-Grant-ClusterAdminJit.ps1 -Requester t1-adm-hvcluster -Hours 4 `
    -Reason 'CHG-2026-1142 Aufbau SRV-HVCL01'

# Verlängern (entfernt und setzt neu mit neuer TTL):
.\07-Grant-ClusterAdminJit.ps1 -Requester t1-adm-hvcluster -Hours 2 -Extend `
    -Reason 'CHG-2026-1142 Verlaengerung Validierung'
```

**Skript** [Cluster.Common.ps1](../Powershell/modul05/Cluster.Common.ps1):

```powershell
#requires -Version 5.1
#requires -Modules ActiveDirectory
# Gemeinsame Hilfsfunktionen fuer modul05 (dot-sourcen: . "$PSScriptRoot\Cluster.Common.ps1")

function Import-ClusterConfig {
    param([Parameter(Mandatory)][string]$Path)
    Import-PowerShellDataFile -Path $Path
}

function Get-JitGroupMember {
    <# Liefert die Mitglieder der JIT-Gruppe inkl. Restlaufzeit; Mitglieder ohne TTL sind dauerhaft. #>
    param(
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Server
    )
    $entries = (Get-ADGroup -Identity $Group -Properties member -ShowMemberTimeToLive -Server $Server).member
    foreach ($entry in $entries) {
        if ($entry -match '^<TTL=(\d+)>,(.+)$') {
            [pscustomobject]@{
                DistinguishedName = $Matches[2]
                Permanent         = $false
                RemainingMinutes  = [math]::Floor([int]$Matches[1] / 60)
                ExpiresAt         = (Get-Date).AddSeconds([int]$Matches[1])
            }
        }
        else {
            [pscustomobject]@{
                DistinguishedName = $entry
                Permanent         = $true
                RemainingMinutes  = $null
                ExpiresAt         = $null
            }
        }
    }
}
```

**Skript** [07-Grant-ClusterAdminJit.ps1](../Powershell/modul05/07-Grant-ClusterAdminJit.ps1):

```powershell
#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 7: JIT-Berechtigung fuer den Cluster-Administrator erteilen (zeitlich begrenzte Mitgliedschaft).
.DESCRIPTION
    Durch ein Mitglied von T1-JIT-Approvers vom Jump Server - niemals durch den Antragsteller selbst.
    Die Mitgliedschaft verfaellt automatisch (PAM-Feature, Schritt 2). Der KDC begrenzt die
    Kerberos-Ticketlaufzeit auf die Restlaufzeit der kuerzesten TTL-Mitgliedschaft.
.EXAMPLE
    .\07-Grant-ClusterAdminJit.ps1 -Requester t1-adm-hvcluster -Hours 4 -Reason 'CHG-2026-1142 Aufbau SRV-HVCL01'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Requester,
    [Parameter(Mandatory)][ValidateLength(8, 300)][string]$Reason,
    [ValidateRange(1, 24)][int]$Hours,
    [switch]$Extend,
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Cluster.Common.ps1"
$cfg = Import-ClusterConfig -Path $ConfigPath
$dc = $cfg.DomainController
if (-not $PSBoundParameters.ContainsKey('Hours')) { $Hours = $cfg.DefaultJitHours }
if ($Hours -gt $cfg.MaxJitHours) { throw "Maximal $($cfg.MaxJitHours) Stunden erlaubt." }

$approver = Get-ADUser -Identity $env:USERNAME -Server $dc
$user = Get-ADUser -Identity $Requester -Server $dc
if ($approver.SID -eq $user.SID) { throw 'Vier-Augen-Prinzip: Selbstfreigabe ist nicht erlaubt.' }
if (-not $user.Enabled) { throw "$Requester ist deaktiviert." }

$members = @(Get-JitGroupMember -Group $cfg.JitGroup -Server $dc)
$permanent = $members | Where-Object Permanent
if ($permanent) {
    throw "Dauerhafte Mitglieder in $($cfg.JitGroup) gefunden - zuerst bereinigen: $($permanent.DistinguishedName -join '; ')"
}
$current = $members | Where-Object DistinguishedName -eq $user.DistinguishedName
if ($current -and -not $Extend) {
    throw "$Requester hat bereits JIT bis $($current.ExpiresAt). Zum Verlaengern -Extend angeben."
}

$ttl = New-TimeSpan -Hours $Hours
if ($PSCmdlet.ShouldProcess("$Requester -> $($cfg.JitGroup)", "JIT fuer $Hours Stunde(n) erteilen")) {
    if ($current) { Remove-ADGroupMember -Identity $cfg.JitGroup -Members $user -Server $dc -Confirm:$false }
    Add-ADGroupMember -Identity $cfg.JitGroup -Members $user -MemberTimeToLive $ttl -Server $dc

    $granted = Get-JitGroupMember -Group $cfg.JitGroup -Server $dc |
        Where-Object DistinguishedName -eq $user.DistinguishedName
    if (-not $granted -or $granted.Permanent) { throw 'TTL-Mitgliedschaft konnte nicht verifiziert werden.' }

    # Nachweis: Transkript (Tag 4) + Ereignis 4728 auf dem DC
    [pscustomobject]@{
        Zeitpunkt = Get-Date -Format s
        Freigeber = $approver.SamAccountName
        Konto     = $user.SamAccountName
        Gruppe    = $cfg.JitGroup
        GueltigBis = $granted.ExpiresAt
        Grund     = $Reason
    } | Format-List
}
```

**Nachweis:** Ereignis **4728** (Mitglied zu globaler Sicherheitsgruppe hinzugefügt) auf dem DC plus PowerShell-Transkript des Freigebers auf dem Jump Server.

---

## 8. Phase D – Cluster aufbauen (Cluster-Admin mit JIT)

Der Cluster-Admin meldet sich per RDP am Jump Server an und öffnet eine **erhöhte Windows PowerShell 5.1** im Verzeichnis `Powershell\modul05`. Alle folgenden Schritte laufen in dieser Sitzung – ohne `Get-Credential`, ausschließlich mit Kerberos.

### Schritt 10: JIT-Zugriff und Voraussetzungen prüfen

`klist purge` verwirft alte Tickets; das neue TGT enthält die JIT-Gruppe. Das Skript prüft je Knoten per WinRM: Kerberos-Anmeldung, Adminrecht **über die DL-Gruppe**, Datacenter-Edition, Virtualisierungsunterstützung, Adapter und Datenplatten.

```powershell
.\10-Test-JitAccessAndPrereqs.ps1
klist   # Ablaufzeit des TGT entspricht höchstens der JIT-Restlaufzeit
```

**Skript** [10-Test-JitAccessAndPrereqs.ps1](../Powershell/modul05/10-Test-JitAccessAndPrereqs.ps1):

```powershell
#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 10: JIT-Zugriff und Voraussetzungen der Knoten pruefen (nur lesend).
.DESCRIPTION
    Als t1-adm-hvcluster auf dem Jump Server. Verwirft vorhandene Kerberos-Tickets, damit das neue
    TGT die JIT-Gruppe enthaelt, und prueft per WinRM auf jedem Knoten:
    Adminrecht ueber die DL-Gruppe, Kerberos, Datacenter-Edition, Virtualisierung, Adapter, Datenplatten.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Cluster.Common.ps1"
$cfg = Import-ClusterConfig -Path $ConfigPath
$dc = $cfg.DomainController
$nodes = $cfg.Nodes | ForEach-Object { $_.Name }

& klist.exe purge | Out-Null
$me = Get-ADUser -Identity $env:USERNAME -Server $dc
$jit = Get-JitGroupMember -Group $cfg.JitGroup -Server $dc | Where-Object DistinguishedName -eq $me.DistinguishedName
if (-not $jit) { throw "Keine aktive JIT-Mitgliedschaft fuer $($me.SamAccountName). Freigabe anfordern (Schritt 7)." }
if ($jit.Permanent) { throw 'Dauerhafte Mitgliedschaft in der JIT-Gruppe - Verstoss gegen das Konzept, Freigeber informieren.' }
Write-Host "JIT aktiv bis $($jit.ExpiresAt) (noch $($jit.RemainingMinutes) Minuten)." -ForegroundColor Green
if ($jit.RemainingMinutes -lt 60) { Write-Warning 'Weniger als 60 Minuten Restlaufzeit - fuer den Clusteraufbau Verlaengerung beantragen.' }

$localAdminSid = (Get-ADGroup -Identity $cfg.LocalAdminGroup -Server $dc).SID.Value
$expectedAdapters = @($cfg.ManagementAdapter) + $cfg.SetAdapters

$report = Invoke-Command -ComputerName $nodes -ArgumentList $localAdminSid, $expectedAdapters -ScriptBlock {
    param($localAdminSid, $expectedAdapters)
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $adapterNames = @(Get-NetAdapter | ForEach-Object Name) +
        @(Get-NetAdapterAdvancedProperty -DisplayName 'Hyper-V Network Adapter Name' -ErrorAction SilentlyContinue |
            ForEach-Object DisplayValue)
    [pscustomobject]@{
        Node           = $env:COMPUTERNAME
        Auth           = $id.AuthenticationType
        IsAdmin        = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        ViaJitGroup    = $id.Groups.Value -contains $localAdminSid
        Datacenter     = $os.Caption -match 'Datacenter'
        Build          = $os.BuildNumber
        DomainMember   = $cs.PartOfDomain
        Virtualization = [bool]($cpu.VirtualizationFirmwareEnabled -or $cs.HypervisorPresent)
        AdaptersFound  = @($expectedAdapters | Where-Object { $_ -in $adapterNames }).Count -eq $expectedAdapters.Count
        DataDisks      = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem }).Count
        ClusterService = [bool](Get-Service ClusSvc -ErrorAction SilentlyContinue)
    }
} | Select-Object Node, Auth, IsAdmin, ViaJitGroup, Datacenter, Build, DomainMember, Virtualization, AdaptersFound, DataDisks, ClusterService

$report | Format-Table -AutoSize

$failed = $report | Where-Object {
    $_.Auth -ne 'Kerberos' -or -not $_.IsAdmin -or -not $_.ViaJitGroup -or -not $_.Datacenter -or
    -not $_.DomainMember -or -not $_.Virtualization -or -not $_.AdaptersFound -or $_.DataDisks -lt 2
}
if ($failed) { throw "Voraussetzungen nicht erfuellt auf: $($failed.Node -join ', ')" }
Write-Host 'Alle Knoten erfuellen die Voraussetzungen.' -ForegroundColor Green
```

Erwartete Ausgabe (gekürzt):

```text
JIT aktiv bis 12.11.2026 14:31:07 (noch 239 Minuten).
Node     Auth     IsAdmin ViaJitGroup Datacenter Build DomainMember Virtualization AdaptersFound DataDisks
SRV-HV01 Kerberos    True        True       True 26100         True           True          True         4
SRV-HV02 Kerberos    True        True       True 26100         True           True          True         4
```

### Schritt 11: Rollen installieren

Hyper-V, Failover Clustering, Data Center Bridging und File Server werden remote installiert; die Knoten starten **nacheinander** neu, das Skript wartet per WinRM auf die Rückkehr.

```powershell
.\11-Install-NodeRoles.ps1
```

**Skript** [11-Install-NodeRoles.ps1](../Powershell/modul05/11-Install-NodeRoles.ps1):

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Schritt 11: Hyper-V, Failover Clustering und Storage-Rollen remote installieren, Knoten nacheinander neu starten.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server. Neustarts erfolgen sequenziell und werden per WinRM abgewartet.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$features = 'Hyper-V', 'Failover-Clustering', 'Data-Center-Bridging', 'FS-FileServer',
    'RSAT-Clustering-PowerShell', 'Hyper-V-PowerShell'

foreach ($node in ($cfg.Nodes | ForEach-Object { $_.Name })) {
    $missing = Get-WindowsFeature -ComputerName $node -Name $features | Where-Object { -not $_.Installed }
    if ($missing -and $PSCmdlet.ShouldProcess($node, "Installieren: $($missing.Name -join ', ')")) {
        $result = Install-WindowsFeature -ComputerName $node -Name $missing.Name -IncludeManagementTools
        if (-not $result.Success) { throw "Installation auf $node fehlgeschlagen." }
        if ($result.RestartNeeded -eq 'Yes' -and $PSCmdlet.ShouldProcess($node, 'Neustart und warten')) {
            Write-Host "$node wird neu gestartet ..." -ForegroundColor Cyan
            Restart-Computer -ComputerName $node -Protocol WSMan -Wait -For PowerShell -Timeout 1800 -Delay 15 -Force
        }
    }
    $state = Get-WindowsFeature -ComputerName $node -Name $features
    if ($state | Where-Object { -not $_.Installed }) { throw "Nicht alle Rollen auf $node installiert." }
    Write-Host "$node : Rollen installiert." -ForegroundColor Green
}
```

### Schritt 12: Netzwerk konfigurieren (SET + SMB-vNICs)

- `MGMT` bleibt ein eigener Adapter → die WinRM-Sitzung reißt beim Anlegen des vSwitch nicht ab.
- `SETswitch` = Switch Embedded Team aus `SET1` + `SET2`, ohne Management-OS-Adapter.
- Host-vNICs `SMB1`/`SMB2` mit fester Team-Zuordnung, statischer IP, **ohne Gateway und DNS-Registrierung**; RDMA wird aktiviert, sofern vorhanden (im Nested-Lab nicht).
- Firewall-Regel `FPS-SMB-In-TCP` für SMB zwischen den Knoten.

```powershell
.\12-Set-NodeNetworking.ps1
```

**Skript** [12-Set-NodeNetworking.ps1](../Powershell/modul05/12-Set-NodeNetworking.ps1):

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Schritt 12: Netzwerk der Knoten konfigurieren (SET-Switch, SMB-vNICs fuer Storage/Live Migration).
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server.
    MGMT bleibt ein eigener physischer Adapter (keine Unterbrechung der WinRM-Sitzung).
    SET1/SET2 bilden einen Switch Embedded Team; darauf zwei Host-vNICs SMB1/SMB2 ohne Gateway/DNS-Registrierung.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath

foreach ($node in $cfg.Nodes) {
    if (-not $PSCmdlet.ShouldProcess($node.Name, 'SET-Switch und SMB-vNICs konfigurieren')) { continue }

    Invoke-Command -ComputerName $node.Name -ArgumentList $cfg, $node -ScriptBlock {
        param($cfg, $node)
        $ErrorActionPreference = 'Stop'

        # Lab: Adapter anhand Hyper-V Device Naming umbenennen; produktiv vorher manuell benennen
        foreach ($wanted in @($cfg.ManagementAdapter) + $cfg.SetAdapters) {
            if (Get-NetAdapter -Name $wanted -ErrorAction SilentlyContinue) { continue }
            $match = Get-NetAdapterAdvancedProperty -DisplayName 'Hyper-V Network Adapter Name' -ErrorAction SilentlyContinue |
                Where-Object DisplayValue -eq $wanted
            if (-not $match) { throw "Adapter '$wanted' auf $env:COMPUTERNAME nicht gefunden." }
            Rename-NetAdapter -Name $match.Name -NewName $wanted
        }

        if (-not (Get-VMSwitch -Name $cfg.SwitchName -ErrorAction SilentlyContinue)) {
            New-VMSwitch -Name $cfg.SwitchName -NetAdapterName $cfg.SetAdapters `
                -EnableEmbeddedTeaming $true -AllowManagementOS $false | Out-Null
        }

        $vnics = @(
            @{ Name = 'SMB1'; Ip = $node.Smb1Ip; Physical = $cfg.SetAdapters[0] }
            @{ Name = 'SMB2'; Ip = $node.Smb2Ip; Physical = $cfg.SetAdapters[1] }
        )
        foreach ($vnic in $vnics) {
            if (-not (Get-VMNetworkAdapter -ManagementOS -Name $vnic.Name -ErrorAction SilentlyContinue)) {
                Add-VMNetworkAdapter -ManagementOS -Name $vnic.Name -SwitchName $cfg.SwitchName
            }
            # Feste Zuordnung vNIC -> physischer Adapter fuer vorhersagbare SMB-Multichannel-Pfade
            Set-VMNetworkAdapterTeamMapping -ManagementOS -VMNetworkAdapterName $vnic.Name `
                -PhysicalNetAdapterName $vnic.Physical
            if ($cfg.SmbVlanId -gt 0) {
                Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $vnic.Name -Access -VlanId $cfg.SmbVlanId
            }

            $alias = "vEthernet ($($vnic.Name))"
            Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Dhcp Disabled
            if (-not (Get-NetIPAddress -InterfaceAlias $alias -IPAddress $vnic.Ip -ErrorAction SilentlyContinue)) {
                New-NetIPAddress -InterfaceAlias $alias -IPAddress $vnic.Ip -PrefixLength $cfg.SmbPrefixLength | Out-Null
            }
            Set-DnsClient -InterfaceAlias $alias -RegisterThisConnectionsAddress $false

            # RDMA nur, wenn die Hardware es kann (im Nested-Lab nicht vorhanden)
            if (Get-NetAdapterRdma -Name $alias -ErrorAction SilentlyContinue) {
                Enable-NetAdapterRdma -Name $alias
            }
        }

        # SMB zwischen den Knoten (S2D/Live Migration); stabiler Regelname statt lokalisiertem Anzeigenamen
        Enable-NetFirewallRule -Name 'FPS-SMB-In-TCP'

        Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $cfg.ManagementAdapter, 'vEthernet (SMB*)' |
            Select-Object @{ n = 'Node'; e = { $env:COMPUTERNAME } }, InterfaceAlias, IPAddress, PrefixLength
    } | Select-Object Node, InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize
}
```

> Produktiv: physische Adapter vorab eindeutig benennen, Storage-VLAN (`SmbVlanId`) und bei RoCE zusätzlich DCB/PFC auf Host **und** Switch konfigurieren. iWARP benötigt kein DCB.

### Schritt 13: Datenplatten für S2D leeren (destruktiv)

S2D benötigt leere, nicht partitionierte Datenträger. Das Skript bricht ab, wenn der Knoten bereits Clustermitglied ist, zeigt die betroffenen Platten an und fragt **je Knoten** nach. Boot- und Systemplatte sind ausgeschlossen.

```powershell
.\13-Clear-S2DDisks.ps1 -WhatIf
.\13-Clear-S2DDisks.ps1
```

**Skript** [13-Clear-S2DDisks.ps1](../Powershell/modul05/13-Clear-S2DDisks.ps1):

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Schritt 13: Datenplatten fuer Storage Spaces Direct leeren (DESTRUKTIV).
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server. Nur auf NEUEN Knoten, die noch kein Clustermitglied sind.
    Zeigt je Knoten die betroffenen Nicht-Boot-/Nicht-System-Datentraeger und fragt vor dem Loeschen nach.
    Mit -WhatIf nur anzeigen.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string[]]$Node,
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
if (-not $Node) { $Node = $cfg.Nodes | ForEach-Object { $_.Name } }

foreach ($computer in $Node) {
    $disks = Invoke-Command -ComputerName $computer -ScriptBlock {
        if ((Get-Service ClusSvc -ErrorAction SilentlyContinue).Status -eq 'Running') {
            throw "$env:COMPUTERNAME ist bereits Clustermitglied - Abbruch."
        }
        Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } |
            Select-Object Number, FriendlyName, SerialNumber, BusType, PartitionStyle,
                @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } }
    } | Select-Object Number, FriendlyName, SerialNumber, BusType, PartitionStyle, SizeGB

    Write-Host "`n$computer - betroffene Datentraeger:" -ForegroundColor Cyan
    $disks | Format-Table -AutoSize
    if (-not $disks) { continue }

    if ($PSCmdlet.ShouldProcess("$computer ($(@($disks).Count) Datentraeger)", 'Pools, Partitionen und ALLE Daten loeschen')) {
        Invoke-Command -ComputerName $computer -ArgumentList (, [int[]]$disks.Number) -ScriptBlock {
            param([int[]]$numbers)
            $ErrorActionPreference = 'Stop'
            Update-StorageProviderCache
            foreach ($pool in @(Get-StoragePool -IsPrimordial $false -ErrorAction SilentlyContinue)) {
                $pool | Set-StoragePool -IsReadOnly $false
                $pool | Get-VirtualDisk | Remove-VirtualDisk -Confirm:$false
                $pool | Remove-StoragePool -Confirm:$false
            }
            Get-PhysicalDisk | Where-Object { [int]$_.DeviceId -in $numbers } | Reset-PhysicalDisk
            foreach ($number in $numbers) {
                $disk = Get-Disk -Number $number
                if ($disk.IsOffline) { Set-Disk -Number $number -IsOffline $false }
                if ($disk.IsReadOnly) { Set-Disk -Number $number -IsReadOnly $false }
                if ($disk.PartitionStyle -ne 'RAW') { Clear-Disk -Number $number -RemoveData -RemoveOEM -Confirm:$false }
                Set-Disk -Number $number -IsReadOnly $true
                Set-Disk -Number $number -IsOffline $true
            }
            [pscustomobject]@{
                Node    = $env:COMPUTERNAME
                CanPool = @(Get-PhysicalDisk -CanPool $true).Count
            }
        } | Select-Object Node, CanPool | Format-Table -AutoSize
    }
}
```

### Schritt 14: Validierung

Zuerst wird SMB (TCP 445) zwischen allen SMB-IP-Adressen geprüft, danach `Test-Cluster` mit den Kategorien **Storage Spaces Direct, Inventory, Network, System Configuration, Hyper-V Configuration**. Der Bericht liegt unter `Documents\ClusterValidation` des Admins; auf Server Core zur Ansicht auf die PAW kopieren.

```powershell
.\14-Test-ClusterReadiness.ps1
```

**Skript** [14-Test-ClusterReadiness.ps1](../Powershell/modul05/14-Test-ClusterReadiness.ps1):

```powershell
#requires -Version 5.1
#requires -Modules FailoverClusters
<#
.SYNOPSIS
    Schritt 14: SMB-Konnektivitaet pruefen und Clustervalidierung inkl. Storage Spaces Direct ausfuehren.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server. Test-Cluster laeuft bewusst VOM Jump Server
    (kein Double Hop, keine Kerberos-Delegation fuer das Protected-Users-Konto noetig).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1",
    [string]$ReportDirectory = "$env:USERPROFILE\Documents\ClusterValidation"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$nodes = $cfg.Nodes | ForEach-Object { $_.Name }

$smbTargets = $cfg.Nodes | ForEach-Object { @{ Node = $_.Name; Ips = @($_.Smb1Ip, $_.Smb2Ip) } }
$connectivity = Invoke-Command -ComputerName $nodes -ArgumentList (, $smbTargets) -ScriptBlock {
    param($targets)
    foreach ($target in $targets | Where-Object { $_.Node -ne $env:COMPUTERNAME }) {
        foreach ($ip in $target.Ips) {
            [pscustomobject]@{
                From   = $env:COMPUTERNAME
                To     = "$($target.Node) ($ip)"
                Smb445 = (Test-NetConnection -ComputerName $ip -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded
            }
        }
    }
} | Select-Object From, To, Smb445
$connectivity | Format-Table -AutoSize
if ($connectivity | Where-Object { -not $_.Smb445 }) { throw 'SMB-Verbindung zwischen Knoten fehlgeschlagen - Netz/Firewall pruefen (Schritt 12).' }

New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
$reportName = Join-Path $ReportDirectory ("{0}-{1:yyyyMMdd-HHmm}" -f $cfg.ClusterName, (Get-Date))
$report = Test-Cluster -Node $nodes -ReportName $reportName `
    -Include 'Storage Spaces Direct', 'Inventory', 'Network', 'System Configuration', 'Hyper-V Configuration'
Write-Host "Validierungsbericht: $($report.FullName)" -ForegroundColor Cyan
Write-Host 'Bericht auf der PAW pruefen. Fehler beheben; Warnungen bewerten und dokumentieren.' -ForegroundColor Yellow
```

> **Fehler** müssen behoben werden. **Warnungen** bewerten und im Change dokumentieren (im Nested-Lab z. B. fehlendes RDMA, Medientyp „Unspecified“, nur ein Subnetz pro Adapter).

### Schritt 15: Cluster erstellen

`-NoStorage` verhindert, dass Datenplatten als klassische Clusterdatenträger übernommen werden. Das vorab angelegte, deaktivierte CNO wird aktiviert. Anschließend werden Clusternetze anhand des Subnetzes benannt (`Management` = Cluster und Client, `SMB1`/`SMB2` = nur Cluster) und der File Share Witness gesetzt.

```powershell
.\15-New-HvCluster.ps1
```

**Skript** [15-New-HvCluster.ps1](../Powershell/modul05/15-New-HvCluster.ps1):

```powershell
#requires -Version 5.1
#requires -Modules FailoverClusters
<#
.SYNOPSIS
    Schritt 15: Cluster mit vorab angelegtem CNO erstellen, Netzwerke benennen und File Share Witness setzen.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server. -NoStorage: Datenplatten werden erst durch S2D (Schritt 16) verwendet.
    Das deaktivierte CNO aus Schritt 3 wird durch New-Cluster aktiviert (Vollzugriff ueber die DL-Gruppe).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$nodes = $cfg.Nodes | ForEach-Object { $_.Name }

$cluster = try { Get-Cluster -Name $cfg.ClusterName -ErrorAction Stop } catch { $null }
if (-not $cluster -and $PSCmdlet.ShouldProcess($cfg.ClusterName, "Cluster aus $($nodes -join ', ') erstellen")) {
    $cluster = New-Cluster -Name $cfg.ClusterName -Node $nodes -StaticAddress $cfg.ClusterIp `
        -NoStorage -AdministrativeAccessPoint ActiveDirectoryAndDns
    Write-Host "Cluster $($cfg.ClusterName) erstellt." -ForegroundColor Green
}
if (-not $cluster) { return }

# Netzwerke anhand des Subnetzes benennen und Rolle setzen
foreach ($definition in $cfg.ClusterNetworks) {
    $network = Get-ClusterNetwork -Cluster $cluster | Where-Object Address -eq $definition.Address
    if (-not $network) { Write-Warning "Clusternetz $($definition.Address) nicht gefunden."; continue }
    if ($network.Name -ne $definition.Name) { $network.Name = $definition.Name }
    if ([int]$network.Role -ne $definition.Role) { $network.Role = $definition.Role }
}

$witness = "\\$($cfg.WitnessServer)\$($cfg.WitnessShare)"
$quorum = Get-ClusterQuorum -Cluster $cluster
if ($quorum.QuorumResource.ResourceType.Name -ne 'File Share Witness' -and
    $PSCmdlet.ShouldProcess($cfg.ClusterName, "File Share Witness $witness setzen")) {
    Set-ClusterQuorum -Cluster $cluster -FileShareWitness $witness | Out-Null
}

Get-ClusterNode -Cluster $cluster | Format-Table Name, State -AutoSize
Get-ClusterNetwork -Cluster $cluster | Format-Table Name, Address, Role, State -AutoSize
Get-ClusterQuorum -Cluster $cluster | Format-List Cluster, QuorumResource
```

### Schritt 16: Storage Spaces Direct aktivieren und Volumes anlegen

```powershell
.\16-Enable-S2D.ps1
```

**Skript** [16-Enable-S2D.ps1](../Powershell/modul05/16-Enable-S2D.ps1):

```powershell
#requires -Version 5.1
#requires -Modules FailoverClusters, Storage
<#
.SYNOPSIS
    Schritt 16: Storage Spaces Direct aktivieren und Cluster Shared Volumes (ReFS, Mirror) anlegen.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server, per CIM-Sitzung auf den Clusternamen.
    Bei zwei Knoten ergibt Mirror einen Two-Way-Mirror; Reservekapazitaet im Pool frei lassen.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$session = New-CimSession -ComputerName $cfg.ClusterName
try {
    if (-not (Get-StoragePool -CimSession $session -FriendlyName $cfg.PoolName -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($cfg.ClusterName, 'Storage Spaces Direct aktivieren')) {
            Enable-ClusterStorageSpacesDirect -CimSession $session -PoolFriendlyName $cfg.PoolName -Confirm:$false
        }
    }

    foreach ($volume in $cfg.Volumes) {
        if (Get-VirtualDisk -CimSession $session -FriendlyName $volume.Name -ErrorAction SilentlyContinue) { continue }
        if ($PSCmdlet.ShouldProcess($volume.Name, "CSV mit $($volume.SizeGB) GB anlegen")) {
            New-Volume -CimSession $session -StoragePoolFriendlyName $cfg.PoolName -FriendlyName $volume.Name `
                -FileSystem CSVFS_ReFS -ResiliencySettingName Mirror -Size ($volume.SizeGB * 1GB) | Out-Null
            Write-Host "Volume $($volume.Name) angelegt." -ForegroundColor Green
        }
    }

    Get-StoragePool -CimSession $session -IsPrimordial $false |
        Format-Table FriendlyName, HealthStatus, OperationalStatus,
            @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } },
            @{ n = 'AllocatedGB'; e = { [math]::Round($_.AllocatedSize / 1GB) } } -AutoSize
    Get-VirtualDisk -CimSession $session |
        Format-Table FriendlyName, ResiliencySettingName, NumberOfDataCopies, HealthStatus, OperationalStatus -AutoSize
    Get-ClusterSharedVolume -Cluster $cfg.ClusterName | Format-Table Name, State, OwnerNode -AutoSize
}
finally {
    Remove-CimSession -CimSession $session
}
```

Die Volumes erscheinen auf allen Knoten unter `C:\ClusterStorage\CSV01` bzw. `CSV02`.

### Schritt 17: Hyper-V-Einstellungen für den Cluster

- Standardpfade für VMs und VHDX auf `C:\ClusterStorage\CSV01`
- Live Migration per **SMB** (Multichannel/RDMA), Kerberos, max. 2 parallel
- Clusterweit `MigrationExcludeNetworks`: Live Migration nur über die SMB-Netze, nie über Management

```powershell
.\17-Set-HyperVClusterSettings.ps1
```

**Skript** [17-Set-HyperVClusterSettings.ps1](../Powershell/modul05/17-Set-HyperVClusterSettings.ps1):

```powershell
#requires -Version 5.1
#requires -Modules FailoverClusters
<#
.SYNOPSIS
    Schritt 17: Hyper-V-Standardpfade auf CSV und Live Migration ueber die SMB-Netze konfigurieren.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server.
    Live Migration: SMB-Transport (nutzt SMB Multichannel/RDMA), Management-Netz ausgeschlossen.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1",
    [ValidateRange(1, 8)][int]$MaxLiveMigrations = 2
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$nodes = $cfg.Nodes | ForEach-Object { $_.Name }
$csvRoot = "C:\ClusterStorage\$($cfg.TestVmVolume)"

if ($PSCmdlet.ShouldProcess(($nodes -join ', '), "Hyper-V-Pfade auf $csvRoot und Live Migration setzen")) {
    Invoke-Command -ComputerName $nodes -ArgumentList $csvRoot, $MaxLiveMigrations -ScriptBlock {
        param($csvRoot, $maxMigrations)
        if (-not (Test-Path $csvRoot)) { throw "CSV $csvRoot fehlt auf $env:COMPUTERNAME." }
        foreach ($folder in 'VMs', 'VHDs') { New-Item -ItemType Directory -Path (Join-Path $csvRoot $folder) -Force | Out-Null }
        Set-VMHost -VirtualMachinePath (Join-Path $csvRoot 'VMs') -VirtualHardDiskPath (Join-Path $csvRoot 'VHDs')
        Enable-VMMigration
        Set-VMHost -VirtualMachineMigrationAuthenticationType Kerberos `
            -VirtualMachineMigrationPerformanceOption SMB `
            -MaximumVirtualMachineMigrations $maxMigrations -MaximumStorageMigrations $maxMigrations
        Get-VMHost | Select-Object @{ n = 'Node'; e = { $env:COMPUTERNAME } }, VirtualMachinePath,
            VirtualMachineMigrationPerformanceOption, MaximumVirtualMachineMigrations
    } | Select-Object Node, VirtualMachinePath, VirtualMachineMigrationPerformanceOption, MaximumVirtualMachineMigrations |
        Format-Table -AutoSize
}

# Clusterweite Live Migration: alle Netze mit Client-Zugriff (Management) ausschliessen
$exclude = Get-ClusterNetwork -Cluster $cfg.ClusterName | Where-Object { [int]$_.Role -ne 1 }
if ($PSCmdlet.ShouldProcess($cfg.ClusterName, "Live Migration ohne: $($exclude.Name -join ', ')")) {
    Get-ClusterResourceType -Cluster $cfg.ClusterName -Name 'Virtual Machine' |
        Set-ClusterParameter -Name MigrationExcludeNetworks -Value ([string]::Join(';', @($exclude.Id)))
}
Get-ClusterResourceType -Cluster $cfg.ClusterName -Name 'Virtual Machine' |
    Get-ClusterParameter -Name MigrationExcludeNetworks | Format-Table Name, Value -AutoSize
```

### Schritt 18: Funktionstest mit hochverfügbarer VM

Eine Test-VM (ohne Betriebssystem) wird auf dem CSV angelegt, als Clusterrolle hinzugefügt, gestartet und zweimal per **Live Migration** verschoben (hin und zurück).

```powershell
.\18-New-ClusterTestVm.ps1
.\18-New-ClusterTestVm.ps1 -Cleanup   # Test-VM wieder entfernen
```

**Skript** [18-New-ClusterTestVm.ps1](../Powershell/modul05/18-New-ClusterTestVm.ps1):

```powershell
#requires -Version 5.1
#requires -Modules FailoverClusters
<#
.SYNOPSIS
    Schritt 18: Hochverfuegbare Test-VM auf dem CSV anlegen und Live Migration in beide Richtungen pruefen.
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server. Die VM benoetigt kein Betriebssystem fuer den Test.
    Mit -Cleanup wird die Test-VM inkl. VHDX wieder entfernt.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1",
    [switch]$Cleanup
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$cluster = $cfg.ClusterName
$vmName = $cfg.TestVmName
$nodes = @($cfg.Nodes | ForEach-Object { $_.Name })
$csvRoot = "C:\ClusterStorage\$($cfg.TestVmVolume)"
$group = try { Get-ClusterGroup -Cluster $cluster -Name $vmName -ErrorAction Stop } catch { $null }

if ($Cleanup) {
    if ($group -and $PSCmdlet.ShouldProcess($vmName, 'Test-VM und Clusterrolle entfernen')) {
        $owner = $group.OwnerNode.Name
        Stop-ClusterGroup -Cluster $cluster -Name $vmName | Out-Null
        Remove-ClusterGroup -Cluster $cluster -Name $vmName -RemoveResources -Force
        Invoke-Command -ComputerName $owner -ArgumentList $vmName, $csvRoot -ScriptBlock {
            param($vmName, $csvRoot)
            Remove-VM -Name $vmName -Force
            Remove-Item -Path (Join-Path $csvRoot "VHDs\$vmName.vhdx") -Force
        }
        Write-Host "$vmName entfernt." -ForegroundColor Green
    }
    return
}

if (-not $group -and $PSCmdlet.ShouldProcess($vmName, "Test-VM auf $($nodes[0]) anlegen und clustern")) {
    Invoke-Command -ComputerName $nodes[0] -ArgumentList $vmName, $csvRoot, $cfg.SwitchName -ScriptBlock {
        param($vmName, $csvRoot, $switchName)
        if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 1GB -Path (Join-Path $csvRoot 'VMs') `
                -NewVHDPath (Join-Path $csvRoot "VHDs\$vmName.vhdx") -NewVHDSizeBytes 20GB -SwitchName $switchName | Out-Null
        }
    }
    Add-ClusterVirtualMachineRole -Cluster $cluster -VMName $vmName | Out-Null
    Start-ClusterGroup -Cluster $cluster -Name $vmName | Out-Null
}

foreach ($i in 1..2) {
    $owner = (Get-ClusterGroup -Cluster $cluster -Name $vmName).OwnerNode.Name
    $target = $nodes | Where-Object { $_ -ne $owner } | Select-Object -First 1
    if (-not $PSCmdlet.ShouldProcess($vmName, "Live Migration $owner -> $target")) { break }
    $duration = Measure-Command {
        Move-ClusterVirtualMachineRole -Cluster $cluster -Name $vmName -Node $target -MigrationType Live | Out-Null
    }
    $now = (Get-ClusterGroup -Cluster $cluster -Name $vmName).OwnerNode.Name
    if ($now -ne $target) { throw "Live Migration nach $target fehlgeschlagen (Besitzer: $now)." }
    Write-Host ("Live Migration {0} -> {1} in {2:N1} s erfolgreich." -f $owner, $target, $duration.TotalSeconds) -ForegroundColor Green
}
```

Optionaler **Ausfalltest** (nur Lab): einen Knoten hart ausschalten und beobachten, dass die VM auf dem anderen Knoten neu startet und die CSVs online bleiben; danach Knoten starten und mit `Get-StorageJob -CimSession SRV-HVCL01` die Resynchronisierung abwarten.

### Schritt 19: Abnahme

```powershell
.\19-Test-ClusterHealth.ps1
```

**Skript** [19-Test-ClusterHealth.ps1](../Powershell/modul05/19-Test-ClusterHealth.ps1):

```powershell
#requires -Version 5.1
#requires -Modules FailoverClusters, Storage
<#
.SYNOPSIS
    Schritt 19: Abnahme - Gesundheitszustand von Cluster, Netzen, Quorum, CSV und S2D pruefen (nur lesend).
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) oder spaeter durch den Betrieb vom Jump Server. Gibt am Ende alle Befunde aus.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath
$cluster = $cfg.ClusterName
$issues = New-Object System.Collections.Generic.List[string]

$clusterNodes = Get-ClusterNode -Cluster $cluster
$clusterNodes | Format-Table Name, State, DrainStatus -AutoSize
$clusterNodes | Where-Object State -ne 'Up' | ForEach-Object { $issues.Add("Knoten $($_.Name): $($_.State)") }

$networks = Get-ClusterNetwork -Cluster $cluster
$networks | Format-Table Name, Address, Role, State -AutoSize
$networks | Where-Object State -ne 'Up' | ForEach-Object { $issues.Add("Netz $($_.Name): $($_.State)") }

$quorum = Get-ClusterQuorum -Cluster $cluster
$witness = $quorum.QuorumResource
if (-not $witness -or $witness.State -ne 'Online') { $issues.Add('Witness fehlt oder ist nicht online.') }
Write-Host "Witness: $($witness.Name) [$($witness.State)]"

$csvs = Get-ClusterSharedVolume -Cluster $cluster
$csvs | Format-Table Name, State, OwnerNode -AutoSize
$csvs | Where-Object State -ne 'Online' | ForEach-Object { $issues.Add("CSV $($_.Name): $($_.State)") }

$session = New-CimSession -ComputerName $cluster
try {
    $subsystem = Get-StorageSubSystem -CimSession $session -FriendlyName 'Clustered*'
    $pool = Get-StoragePool -CimSession $session -FriendlyName $cfg.PoolName
    if ($pool.HealthStatus -ne 'Healthy') { $issues.Add("Pool $($pool.FriendlyName): $($pool.HealthStatus)") }

    Get-VirtualDisk -CimSession $session | Where-Object HealthStatus -ne 'Healthy' |
        ForEach-Object { $issues.Add("Virtueller Datentraeger $($_.FriendlyName): $($_.HealthStatus)/$($_.OperationalStatus)") }
    Get-PhysicalDisk -CimSession $session -StoragePool $pool | Where-Object HealthStatus -ne 'Healthy' |
        ForEach-Object { $issues.Add("Physischer Datentraeger $($_.SerialNumber): $($_.HealthStatus)") }
    Get-StorageJob -CimSession $session | Where-Object JobState -eq 'Running' |
        ForEach-Object { $issues.Add("Storage-Job laeuft noch: $($_.Name) ($($_.PercentComplete) %)") }
    $subsystem | Debug-StorageSubSystem |
        ForEach-Object { $issues.Add("Health Service: $($_.FaultingObjectDescription) - $($_.Reason)") }
}
finally {
    Remove-CimSession -CimSession $session
}

if ($issues.Count) {
    Write-Warning "Befunde ($($issues.Count)):"
    $issues | ForEach-Object { Write-Warning "  $_" }
}
else {
    Write-Host "Abnahme OK: $cluster ist gesund." -ForegroundColor Green
}
```

Abnahme ist erreicht, wenn `Abnahme OK` erscheint, Validierungsbericht und Ausgabe im Change abgelegt sind und keine Storage-Jobs mehr laufen.

---

## 9. Phase E – Abschluss und Rechteentzug

### Schritt 8: JIT entziehen (vorzeitig) und Nachkontrolle

Läuft die TTL ab, entfernt der DC die Mitgliedschaft selbstständig. Ist die Arbeit früher beendet, entzieht der Freigeber die Rechte sofort. Bereits ausgestellte Kerberos-Tickets gelten bis zu ihrem Ablauf (höchstens Rest-TTL) weiter; im Notfall `-DisableAccount` verwenden und Sitzungen abmelden.

```powershell
.\08-Revoke-ClusterAdminJit.ps1 -Requester t1-adm-hvcluster
# Notfall:
.\08-Revoke-ClusterAdminJit.ps1 -Requester t1-adm-hvcluster -DisableAccount
```

**Skript** [08-Revoke-ClusterAdminJit.ps1](../Powershell/modul05/08-Revoke-ClusterAdminJit.ps1):

```powershell
#requires -Version 5.1
#requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Schritt 8: JIT-Berechtigung vorzeitig entziehen (nach Abschluss oder im Notfall).
.DESCRIPTION
    Durch einen Freigeber vom Jump Server. Bereits ausgestellte Kerberos-Tickets bleiben bis zu
    ihrem Ablauf (max. Rest-TTL) gueltig; im Notfall zusaetzlich Sitzungen beenden und Konto sperren.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Requester,
    [switch]$DisableAccount,
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Cluster.Common.ps1"
$cfg = Import-ClusterConfig -Path $ConfigPath
$dc = $cfg.DomainController
$user = Get-ADUser -Identity $Requester -Server $dc

$current = Get-JitGroupMember -Group $cfg.JitGroup -Server $dc |
    Where-Object DistinguishedName -eq $user.DistinguishedName
if ($current -and $PSCmdlet.ShouldProcess("$Requester -> $($cfg.JitGroup)", 'JIT entziehen')) {
    Remove-ADGroupMember -Identity $cfg.JitGroup -Members $user -Server $dc -Confirm:$false
    Write-Host "JIT fuer $Requester entzogen." -ForegroundColor Green
}
elseif (-not $current) {
    Write-Host "$Requester hat keine (aktive) JIT-Mitgliedschaft." -ForegroundColor Yellow
}

if ($DisableAccount -and $PSCmdlet.ShouldProcess($Requester, 'Konto deaktivieren (Notfall)')) {
    Disable-ADAccount -Identity $user -Server $dc
    Write-Warning "$Requester deaktiviert. Offene Sitzungen auf Jump Server und Knoten abmelden."
}

Get-JitGroupMember -Group $cfg.JitGroup -Server $dc | Format-Table -AutoSize
```

**Nachkontrolle (Cluster-Admin, nach Ablauf):**

```powershell
klist purge
Invoke-Command -ComputerName SRV-HV01 { whoami }   # erwartet: Zugriff verweigert
```

**Danach im Betrieb:**

- `DL-HVCluster-LocalAdmins` bleibt bestehen, ist aber ohne aktive JIT-Mitglieder wirkungslos.
- Routineaufgaben (Knoten pausieren, Health-Abfrage) über einen **JEA-Endpunkt** (Tag 4) statt über Vollrechte.
- Witness, Validierungsbericht, Konfiguration und Changes revisionssicher ablegen.

---

## 10. Troubleshooting

| Symptom | Ursache | Lösung |
|---------|---------|--------|
| `Add-ADGroupMember: … MemberTimeToLive` nicht unterstützt | PAM-Feature nicht aktiv | Schritt 2, Replikation abwarten |
| Schritt 10: `ViaJitGroup = False` | altes TGT ohne Gruppe | `klist purge`, neu anmelden; Schritt 5 prüfen |
| Zugriff verweigert trotz JIT | Mitgliedschaft abgelaufen / noch nicht repliziert | `Get-ADGroup … -ShowMemberTimeToLive`, ggf. Schritt 7 mit `-Extend` |
| `New-Cluster`: CNO kann nicht aktiviert werden | fehlender Vollzugriff auf CNO | Schritt 3, ACL am CNO prüfen |
| Witness offline | Freigabe/NTFS ohne `SRV-HVCL01$` | Schritt 6, `Get-SmbShareAccess` |
| `Enable-ClusterStorageSpacesDirect`: keine geeigneten Datenträger | Platten nicht leer oder `CanPool = False` | Schritt 13, `Get-PhysicalDisk -CanPool $true` |
| Hyper-V-Installation schlägt im Lab fehl | Nested Virtualization nicht aktiv | Schritt 0: `ExposeVirtualizationExtensions`, statischer RAM |
| VMs im Nested-Lab ohne Netzwerk | MAC-Spoofing aus | `Set-VMNetworkAdapter -MacAddressSpoofing On` am Lab-Host |
| `CredSSP`/„Double Hop“-Fehler | Befehl auf Knoten greift auf zweites System zu | Befehl vom Jump Server direkt gegen das Zielsystem ausführen |

---

## 11. Sicherheitsreferenzen

### 11.1 BSI IT-Grundschutz

| Baustein | Anforderung (Auszug) | Umsetzung heute |
|----------|----------------------|-----------------|
| ORP.4 Identitäts- und Berechtigungsmanagement | Vergabe nach Erforderlichkeit, Vier-Augen-Prinzip | JIT-Gruppe, Freigeber ≠ Antragsteller, TTL |
| OPS.1.1.2 Ordnungsgemäße IT-Administration | getrennte Admin-Konten, Protokollierung | Tier-1-Konto, Jump Server, Transkript |
| SYS.1.5 Virtualisierung | Absicherung des Virtualisierungsservers und der Verwaltung | Server Core, getrennte Netze, Tier-Einordnung |
| SYS.1.1 Allgemeiner Server | Minimale Rollen, sichere Administration | nur benötigte Features, kein CredSSP |
| APP.2.2 Active Directory | Delegation von Rechten | delegiertes CNO, `member`-Schreibrecht |

### 11.2 Microsoft Learn

- [Privileged Access Management für AD DS (zeitlich begrenzte Mitgliedschaften)](https://learn.microsoft.com/de-de/microsoft-identity-manager/pam/privileged-identity-management-for-active-directory-domain-services)
- [Add-ADGroupMember (-MemberTimeToLive)](https://learn.microsoft.com/de-de/powershell/module/activedirectory/add-adgroupmember)
- [Sicherheitsgruppe „Geschützte Benutzer“](https://learn.microsoft.com/de-de/windows-server/security/credentials-protection-and-management/protected-users-security-group)
- [Vorab bereitgestellte Clustercomputerobjekte in AD DS](https://learn.microsoft.com/de-de/windows-server/failover-clustering/prestage-cluster-adds)
- [Erstellen eines Failoverclusters](https://learn.microsoft.com/de-de/windows-server/failover-clustering/create-failover-cluster)
- [Bereitstellen von Storage Spaces Direct](https://learn.microsoft.com/de-de/windows-server/storage/storage-spaces/deploy-storage-spaces-direct)
- [Storage Spaces Direct – Übersicht](https://learn.microsoft.com/de-de/windows-server/storage/storage-spaces/storage-spaces-direct-overview)
- [Planen von Volumes in S2D](https://learn.microsoft.com/de-de/windows-server/storage/storage-spaces/plan-volumes)
- [RDMA und Switch Embedded Teaming (SET)](https://learn.microsoft.com/de-de/windows-server/virtualization/hyper-v-virtual-switch/rdma-and-switch-embedded-teaming)
- [Dateifreigabezeuge](https://learn.microsoft.com/de-de/windows-server/failover-clustering/file-share-witness) und [Quorum verwalten](https://learn.microsoft.com/de-de/windows-server/failover-clustering/manage-cluster-quorum)
- [Geschachtelte Virtualisierung aktivieren](https://learn.microsoft.com/de-de/virtualization/hyper-v-on-windows/user-guide/enable-nested-virtualization)

---

## 12. Übungen Tag 5

### Übung 5.1: JIT-Grundlagen
1. Schritte 2–4 durchführen.
2. Einem Testkonto für **10 Minuten** die JIT-Gruppe zuweisen und mit `Get-ADGroup … -ShowMemberTimeToLive` die Restlaufzeit beobachten.
3. Mit `klist` zeigen, dass das TGT nach `klist purge` höchstens bis zum TTL-Ende gültig ist.
4. Selbstfreigabe versuchen – das Skript muss abbrechen.

### Übung 5.2: Vorbereitung durch getrennte Rollen
1. Schritte 5 und 6 mit den jeweils zuständigen Konten ausführen.
2. Nachweisen, dass `t1-adm-hvcluster` **ohne** JIT keinen Zugriff auf `SRV-HV01` hat.

### Übung 5.3: Clusteraufbau
1. JIT für 4 Stunden erteilen (Schritt 7).
2. Schritte 10–17 ausführen, Validierungsbericht bewerten.
3. Clusternetze und Witness mit `Get-ClusterNetwork`/`Get-ClusterQuorum` erklären.

### Übung 5.4: Betrieb und Abschluss
1. Test-VM anlegen, Live Migration durchführen, Ausfalltest (Lab).
2. Abnahme mit Schritt 19.
3. JIT vorzeitig entziehen (Schritt 8) und den Verlust der Rechte nachweisen.

---

## 13. Zusammenfassung

✅ Zeitlich begrenzte Gruppenmitgliedschaften (PAM-Feature) liefern JIT mit AD-Bordmitteln  
✅ Vier-Augen-Freigabe: Freigeber dürfen nur `member` der JIT-Gruppe schreiben, Selbstfreigabe ist unterbunden  
✅ Vorab angelegtes CNO und Witness: Der Cluster-Admin benötigt keine Erstellrechte in AD  
✅ Hyper-V-Cluster mit S2D vollständig per PowerShell vom Jump Server – ohne CredSSP und Kerberos-Delegation  
✅ Getrennte Netze: Management, Storage/Live Migration über SET-vNICs  
✅ Validierung, Funktionstest und Abnahme sind skriptgesteuert und nachweisbar  
✅ Rechte verfallen automatisch; vorzeitiger Entzug und Notfallsperre sind vorbereitet  

---

## Navigation

⬅️ [Tag 4: PowerShell Security – JEA und DSC](Tag4-PowerShell-Security.md) · [Referenzen](Referenzen.md)
