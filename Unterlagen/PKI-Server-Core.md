# Zusatzmodul: Zweistufige PKI auf Windows Server 2025 Core

## Ziel und Einordnung

Aufbau einer **Standalone Offline Root CA** und einer **domänenintegrierten Enterprise Issuing CA**. Alle Server laufen als **Server Core**, alle Schritte erfolgen über Windows PowerShell 5.1 und die Windows-Werkzeuge `certutil.exe`/`certreq.exe`, ohne lokale MMC oder Desktop Experience. „ESF“ wird hier als **EFS (Encrypting File System)** und „ESF Agent“ als **EFS Recovery Agent (DRA)** verstanden, nicht als Enrollment Agent.

Das Modul kann nach Tag 3 durchgeführt werden; das Code-Signing-Zertifikat wird an Tag 4 verwendet. Es ist ein **Lab**, keine ungeprüft produktionsreife oder pauschal BSI-konforme PKI. Kryptoverfahren, Laufzeiten, Rollen und Wiederherstellung müssen vor Produktion freigegeben werden.

## 1. Architektur und Voraussetzungen

```text
CORE-ROOT01 (Workgroup, offline, Tier 0)
  SecureOps-RootCA                 RSA 4096 / SHA-256, 15 Jahre
      |
      | kontrollierter Dateitransfer: CSR -> Zertifikat + Root-CRL
      v
CORE-CA01 (secureops.local, Tier 0)
  SecureOps-IssuingCA01            RSA 4096 / SHA-256, 5 Jahre
      |
      +-- SecureOpsComputer        Server-/Client-Authentifizierung
      +-- SecureOpsWebServer       nur Server-Authentifizierung, Freigabe
      +-- SecureOpsCodeSigning     nur Code Signing, Freigabe
      +-- SecureOpsEFS             nur EFS
      +-- SecureOpsEFSRecovery     nur EFS Recovery, Freigabe

CORE-PKIWEB01 (separater Core-Webserver)
  http://pki.secureops.local/pki/   öffentliche CA-Zertifikate + CRLs
```

- Vorhandene AD-Domäne `secureops.local`, DNS, Zeitsynchronisation, vollständig aktualisierte Core-Server. Namen und URLs **vor** der ersten Ausstellung anpassen; bestehende Zertifikate behalten ihre URLs.
- Root: **kein Domänenbeitritt, kein Netzadapter im Betrieb**. Lokale Konsole, gesicherte Datenträger, Offline-Patchverfahren. Bei Virtualisierung auch Hypervisor, Backups und Konsole als Tier 0 behandeln.
- Issuing CA: eigener Member Server, **kein DC**, kein IIS, kein Web Enrollment, kein CES/CEP, kein NDES. Root niemals zum Signieren ans Netz anschließen.
- D: und E: sind vorbereitete lokale Volumes für CA-Datenbank und Logs. Skripte formatieren keine Datenträger. Alle Transferverzeichnisse vorab auf Administratoren und SYSTEM beschränken.
- Erhöhte **Windows PowerShell 5.1** (`powershell.exe -NoProfile`), nicht PowerShell 7 für AD-CS-/IIS-Administration. Die Root- und Enterprise-CA-Installation (Abschnitte 3–5) ist hier **vollständig als Einzelschritte** dokumentiert; die Skripte in [modul04](../Powershell/modul04/) sind nur eine optionale Automatisierung derselben Schritte.
- Root-Installation als lokaler Administrator. Erste Enterprise-CA-Installation und Vorlagenerstellung mit zeitlich begrenztem **Enterprise-Admin** und lokalen Administratorrechten auf der CA; danach Mitgliedschaft entfernen und getrennte CA-Verwalter/Zertifikatmanager einsetzen.
- Die Schritte sind absichtlich **keine Reconfiguration-/Repair-Anleitung**: vorhandene CA, vorhandene CAPolicy und vorhandene Vorlagen führen zum Abbruch. Bei Teilfehlern Zustand untersuchen, nicht blind erneut starten.

### Kryptografie und Laufzeiten

CA-Schlüssel: RSA 4096, SHA-256; Endzertifikate mindestens RSA 3072, Gültigkeit ein Jahr, Erneuerungsfenster sechs Wochen. Die Root begrenzt die Issuing CA auf fünf Jahre; die Issuing CA begrenzt ausgestellte Zertifikate zusätzlich auf zwei Jahre. Die effektive Laufzeit kann durch das Ablaufdatum der übergeordneten CA kürzer sein.

Diese Werte sind **Lab-Parameter**, keine Zusicherung über den gesamten BSI-Empfehlungszeitraum. Vor Produktion aktuelle **TR-02102-1**, Verwendungszweck und Migrations-/PQC-Strategie prüfen. HSM und dessen KSP vor der Installation planen; die Skripte verwenden ausdrücklich einen **Software-KSP** für das Lab.

## 2. Separaten HTTP-Publikationspunkt einrichten

Auf **CORE-PKIWEB01**, nicht auf einer CA. Nur Zertifikate und CRLs sind öffentlich; niemals Schlüssel, PFX, CSR-Sammlungen oder Backups in den Webroot kopieren. DNS-A-Eintrag `pki.secureops.local` auf diesen Host bzw. einen hochverfügbaren Publikationsdienst setzen.

```powershell
$ErrorActionPreference = 'Stop'
Install-WindowsFeature Web-Server, Web-Static-Content -IncludeManagementTools
Import-Module WebAdministration
New-Item -Path D:\PKI-Public -ItemType Directory -Force
New-Website -Name PKI-Publication -Port 80 -HostHeader pki.secureops.local `
    -PhysicalPath D:\PKI-Public
Set-WebConfigurationProperty -PSPath 'IIS:\Sites\PKI-Publication' `
    -Filter system.webServer/directoryBrowse -Name enabled -Value $false
foreach ($entry in @(
    @{ Extension = '.crt'; Mime = 'application/x-x509-ca-cert' },
    @{ Extension = '.crl'; Mime = 'application/pkix-crl' }
)) {
    $filter = "system.webServer/staticContent/mimeMap[@fileExtension='$($entry.Extension)']"
    if (-not (Get-WebConfiguration -PSPath 'IIS:\Sites\PKI-Publication' -Filter $filter)) {
        Add-WebConfigurationProperty -PSPath 'IIS:\Sites\PKI-Publication' `
            -Filter system.webServer/staticContent -Name '.' `
            -Value @{ fileExtension = $entry.Extension; mimeType = $entry.Mime }
    }
}
```

Default-Site/ungenutzte Bindings auf dem dedizierten Lab-Host deaktivieren, anonymen **Lesezugriff** testen; WebDAV, Uploads, Verzeichnisauflistung und ausführbare Inhalte nicht aktivieren. NTFS: SYSTEM/Administratoren Vollzugriff, Webserver-Identität nur Lesen/Ausführen; Schreibzugriff ausschließlich für den kontrollierten Publikationsprozess.

Nur eingehendes TCP 80 aus den benötigten Clientnetzen erlauben; vom Administrationsnetz WinRM mit Kerberos bzw. HTTPS. Keine Verbindung vom Webserver zur Root und kein allgemeiner administrativer Zugriff vom Webserver auf die Issuing CA.

**Warum HTTP?** CRLs und CA-Zertifikate sind signierte öffentliche Objekte. Ihr Abruf darf keine Anmeldung und keine ihrerseits von dieser PKI abhängige TLS-Prüfung benötigen. Integrität kommt aus der Signatur; DNS-/HTTP-Verfügbarkeit bleibt kritisch. Das ist **kein** Grund, Enrollment oder Verwaltungszugriffe unverschlüsselt zu betreiben.

## 3. Offline Root CA installieren

Auf **CORE-ROOT01**, Netzadapter bereits getrennt. Das leere Transferverzeichnis liegt lokal, der Austausch erfolgt über kontrollierte Medien. Alle Schritte in einer erhöhten **Windows PowerShell 5.1** (`powershell.exe -NoProfile`) in derselben Sitzung ausführen.

> Die Schritte 3.1–3.6 entsprechen dem optionalen Skript [Install-Ca.ps1](../Powershell/modul04/Install-Ca.ps1) `-Role Root`. Sie werden hier bewusst einzeln ausgeführt, damit jeder Schritt nachvollzogen und geprüft werden kann.

#### 3.1 Variablen und Fehlerbehandlung

```powershell
$ErrorActionPreference = 'Stop'
$CAName   = 'SecureOps-RootCA'
$PkiUrl   = 'http://pki.secureops.local/pki'      # ohne abschliessenden Schraegstrich
$Transfer = 'C:\PKI-Transfer'
$DbDir    = 'D:\CA\Database'
$LogDir   = 'E:\CA\Logs'
$CertEnroll = "$env:SystemRoot\System32\CertSrv\CertEnroll"

# certutil/certreq werfen keine PowerShell-Fehler; Exitcode deshalb pruefen
function Invoke-CertUtil {
    & certutil.exe @args
    if ($LASTEXITCODE -ne 0) { throw "certutil $($args -join ' ') fehlgeschlagen (Exitcode $LASTEXITCODE)" }
}
```

#### 3.2 Vorbedingungen prüfen

```powershell
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType  # erwartet: Server Core
(Get-CimInstance Win32_ComputerSystem).PartOfDomain                                       # erwartet: False
Get-NetAdapter | Where-Object Status -eq 'Up'                                             # erwartet: keine Ausgabe
Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'                 # erwartet: False
Test-Path "$env:SystemRoot\CAPolicy.inf"                                                  # erwartet: False

New-Item -ItemType Directory -Path $DbDir, $LogDir, $Transfer -Force | Out-Null
```

Weicht ein Ergebnis ab: **abbrechen** und Zustand klären, nicht „drüberinstallieren“.

#### 3.3 CAPolicy.inf der Root CA

Die Datei muss **vor** der Rolleninstallation unter `C:\Windows\CAPolicy.inf` liegen (ANSI/ASCII):

```powershell
@'
[Version]
Signature="$Windows NT$"

[Certsrv_Server]
RenewalKeyLength=4096
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=15
CRLPeriod=Weeks
CRLPeriodUnits=26
CRLDeltaPeriod=Days
CRLDeltaPeriodUnits=0
LoadDefaultTemplates=0
AlternateSignatureAlgorithm=0

[BasicConstraintsExtension]
PathLength=1
Critical=Yes

[CRLDistributionPoint]
Empty=True

[AuthorityInformationAccess]
Empty=True
'@ | Set-Content -Path "$env:SystemRoot\CAPolicy.inf" -Encoding Ascii

Get-Content "$env:SystemRoot\CAPolicy.inf"
```

| Eintrag | Wirkung |
|---------|---------|
| `PathLength=1` | Unter der Root ist genau **eine** CA-Ebene erlaubt |
| `CRLDistributionPoint/AuthorityInformationAccess Empty` | Das selbstsignierte Root-Zertifikat enthält **kein** AIA/CDP |
| `LoadDefaultTemplates=0` | Keine Standardvorlagen (bei Standalone ohnehin irrelevant, schadet nicht) |
| `AlternateSignatureAlgorithm=0` | Klassische PKCS#1-v1.5-Signatur für maximale Kompatibilität |

#### 3.4 Rolle installieren und Root CA einrichten

```powershell
$feature = Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools
$feature   # Success = True, RestartNeeded = No; sonst erst neu starten

Install-AdcsCertificationAuthority `
    -CAType StandaloneRootCA `
    -CACommonName $CAName `
    -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' `
    -KeyLength 4096 `
    -HashAlgorithmName SHA256 `
    -ValidityPeriod Years -ValidityPeriodUnits 15 `
    -DatabaseDirectory $DbDir `
    -LogDirectory $LogDir `
    -Force
```

Mit HSM statt `Microsoft Software Key Storage Provider` den KSP-Namen des Herstellers verwenden (`certutil -csplist`).

#### 3.5 Veröffentlichung, Laufzeiten und Hardening konfigurieren

AIA/CDP gelten für die **von der Root ausgestellten** Zertifikate (also die Issuing CA). `1:` = lokale Datei veröffentlichen, `2:` = URL in Zertifikate aufnehmen. `\n` ist hier **wörtlich** gemeint (certutil-Trennzeichen), kein PowerShell-Escape.

```powershell
Invoke-CertUtil -setreg CA\CRLPublicationURLs  "1:$CertEnroll\%3%8%9.crl\n2:$PkiUrl/%3%8%9.crl"
Invoke-CertUtil -setreg CA\CACertPublicationURLs "1:$CertEnroll\%1_%3%4.crt\n2:$PkiUrl/$CAName.crt"

# Basis-CRL 26 Wochen, 14 Tage Ueberlappung, keine Delta-CRL
Invoke-CertUtil -setreg CA\CRLPeriod Weeks
Invoke-CertUtil -setreg CA\CRLPeriodUnits 26
Invoke-CertUtil -setreg CA\CRLOverlapPeriod Days
Invoke-CertUtil -setreg CA\CRLOverlapPeriodUnits 14
Invoke-CertUtil -setreg CA\CRLDeltaPeriodUnits 0

# Maximale Laufzeit der von der Root ausgestellten (Sub-CA-)Zertifikate
Invoke-CertUtil -setreg CA\ValidityPeriod Years
Invoke-CertUtil -setreg CA\ValidityPeriodUnits 5

# Hardening: vollstaendiges CA-Audit, verschluesselte RPC-Antraege, keine freien SAN-Attribute
Invoke-CertUtil -setreg CA\AuditFilter 127
Invoke-CertUtil -setreg CA\InterfaceFlags +IF_ENFORCEENCRYPTICERTREQUEST
Invoke-CertUtil -setreg policy\EditFlags -EDITF_ATTRIBUTESUBJECTALTNAME2
auditpol.exe /set /subcategory:"{0CCE9221-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable

Restart-Service CertSvc
Invoke-CertUtil -crl
```

#### 3.6 Öffentliche Dateien exportieren und prüfen

```powershell
Invoke-CertUtil -ca.cert "$Transfer\$CAName.crt"
Copy-Item "$CertEnroll\$CAName.crl" $Transfer

Get-FileHash "$Transfer\$CAName.crt" -Algorithm SHA256
certutil.exe -dump "$Transfer\$CAName.crt"   # Thumbprint (Cert Hash sha1), Basic Constraints, Laufzeit
certutil.exe -dump "$Transfer\$CAName.crl"   # NextUpdate ca. 26 Wochen in der Zukunft
certutil.exe -getreg CA\CRLPublicationURLs
certutil.exe -getreg CA\CACertPublicationURLs
```

Ergebnis: keine Default-Vorlagen, Root-Zertifikat ohne AIA/CDP, maximal eine untergeordnete CA-Ebene. Die Root publiziert AIA/CDP für **von ihr ausgestellte** Zertifikate. Basis-CRL: 26 Wochen, Überlappung 14 Tage, keine Delta-CRLs.

Den im Zertifikat angezeigten **Thumbprint unabhängig** protokollieren (für die spätere Vertrauensinstallation). Zusätzlich SHA-256-Dateihashes über einen getrennten Kanal vergleichen. Ein Hash auf demselben unkontrollierten USB-Medium ist kein Herkunftsnachweis.

Öffentliche Dateien über kontrollierte Medien auf den Webserver übertragen:

```powershell
# Auf CORE-PKIWEB01, nach kontrolliertem Import nach C:\PKI-Transfer:
Copy-Item C:\PKI-Transfer\SecureOps-RootCA.crt D:\PKI-Public
Copy-Item C:\PKI-Transfer\SecureOps-RootCA.crl D:\PKI-Public
Invoke-WebRequest http://pki.secureops.local/pki/SecureOps-RootCA.crt -UseBasicParsing
Invoke-WebRequest http://pki.secureops.local/pki/SecureOps-RootCA.crl -UseBasicParsing
```

Root sichern (Abschnitt 10) und herunterfahren, solange keine Signierung bzw. CRL-Erneuerung erforderlich ist. Offline bedeutet nicht nur „Firewall eingeschaltet“.

## 4. Enterprise Issuing CA vorbereiten und CSR signieren

Auf **CORE-CA01** mit den zeitlich begrenzten Installationsrechten (Enterprise Admin + lokaler Administrator), erhöhte **Windows PowerShell 5.1**, alle Schritte in derselben Sitzung.

> Die Schritte 4.1–4.4 entsprechen dem optionalen Skript [Install-Ca.ps1](../Powershell/modul04/Install-Ca.ps1) `-Role Issuing`.

#### 4.1 Variablen und Vorbedingungen

```powershell
$ErrorActionPreference = 'Stop'
$CAName   = 'SecureOps-IssuingCA01'
$PkiUrl   = 'http://pki.secureops.local/pki'
$Transfer = 'C:\PKI-Transfer'
$DbDir    = 'D:\CA\Database'
$LogDir   = 'E:\CA\Logs'
$CertEnroll = "$env:SystemRoot\System32\CertSrv\CertEnroll"

function Invoke-CertUtil {
    & certutil.exe @args
    if ($LASTEXITCODE -ne 0) { throw "certutil $($args -join ' ') fehlgeschlagen (Exitcode $LASTEXITCODE)" }
}

(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType  # Server Core
$cs = Get-CimInstance Win32_ComputerSystem
$cs.PartOfDomain       # erwartet: True
$cs.DomainRole         # erwartet: 3 (Member Server); 4/5 = DC -> abbrechen
Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'                 # erwartet: False
Test-Path "$env:SystemRoot\CAPolicy.inf"                                                  # erwartet: False
Invoke-WebRequest "$PkiUrl/SecureOps-RootCA.crl" -UseBasicParsing | Select-Object StatusCode  # 200

New-Item -ItemType Directory -Path $DbDir, $LogDir, $Transfer -Force | Out-Null
```

#### 4.2 CAPolicy.inf (Policy-Datei) der Enterprise CA

Die Policy-Datei steuert, was im **CSR der Issuing CA** angefordert wird (u. a. Zertifikatsrichtlinie mit CPS-Verweis, Pfadlänge) sowie die Grundeinstellungen der CA bei der Installation:

```powershell
@'
[Version]
Signature="$Windows NT$"

[PolicyStatementExtension]
Policies=AllIssuancePolicy
Critical=False

[AllIssuancePolicy]
OID=2.5.29.32.0
Notice="SecureOps Lab PKI. Nutzung nur gemaess Certificate Practice Statement."
URL="http://pki.secureops.local/pki/cps.html"

[Certsrv_Server]
RenewalKeyLength=4096
CRLPeriod=Days
CRLPeriodUnits=7
CRLDeltaPeriod=Days
CRLDeltaPeriodUnits=0
LoadDefaultTemplates=0
AlternateSignatureAlgorithm=0

[BasicConstraintsExtension]
PathLength=0
Critical=Yes
'@ | Set-Content -Path "$env:SystemRoot\CAPolicy.inf" -Encoding Ascii

Get-Content "$env:SystemRoot\CAPolicy.inf"
```

| Abschnitt / Eintrag | Wirkung |
|---------------------|---------|
| `[PolicyStatementExtension]` | Nimmt die Erweiterung *Certificate Policies* in das Issuing-CA-Zertifikat auf |
| `OID=2.5.29.32.0` | *All Issuance Policies* (anyPolicy): die CA darf Zertifikate mit beliebigen Ausstellungsrichtlinien ausstellen. Für Produktion **eigene OID** unter der IANA-PEN der Organisation vergeben (z. B. `1.3.6.1.4.1.<PEN>.…`) und ggf. zusätzlich aufnehmen |
| `Notice` / `URL` | Benutzerhinweis und Verweis auf das CPS; nur ASCII-Zeichen im Notice-Text. Die URL muss per HTTP anonym erreichbar sein (siehe 4.5) |
| `PathLength=0`, `Critical=Yes` | Die Issuing CA darf **keine** weiteren CAs ausstellen |
| `LoadDefaultTemplates=0` | Nach der Installation werden **keine** Standardvorlagen (User, Computer, WebServer …) veröffentlicht; nur die eigenen Vorlagen aus Abschnitt 6 |
| `CRLPeriod*` | Erste CRL bereits mit 7 Tagen, keine Delta-CRL (wird in 5.3 nochmals fest gesetzt) |
| `RenewalKeyLength=4096` | Schlüssellänge bei CA-Erneuerung mit neuem Schlüssel |

`RenewalValidityPeriod*` fehlt bewusst: Die Laufzeit einer untergeordneten CA bestimmt die **Root** (`ValidityPeriodUnits=5`, Abschnitt 3.5), nicht die CAPolicy.

#### 4.3 Rolle installieren und CSR erzeugen

```powershell
$feature = Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools
$feature   # Success = True, RestartNeeded = No

Install-AdcsCertificationAuthority `
    -CAType EnterpriseSubordinateCA `
    -CACommonName $CAName `
    -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' `
    -KeyLength 4096 `
    -HashAlgorithmName SHA256 `
    -DatabaseDirectory $DbDir `
    -LogDirectory $LogDir `
    -OutputCertRequestFile "$Transfer\$CAName.req" `
    -Force
```

Die Warnung, dass die Installation unvollständig ist, ist **erwartet**: Die CA wartet auf ihr signiertes Zertifikat. `CertSvc` startet erst nach Abschnitt 5.

#### 4.4 CSR prüfen

```powershell
certutil.exe -dump "$Transfer\$CAName.req"
Get-FileHash "$Transfer\$CAName.req" -Algorithm SHA256
```

Im Dump prüfen: Subject `CN=SecureOps-IssuingCA01, DC=…`, RSA 4096, **Basic Constraints** `Subject Type=CA, Path Length Constraint=0`, **Certificate Policies** `2.5.29.32.0` mit CPS-URL, kein SAN.

#### 4.5 CPS auf dem Publikationspunkt bereitstellen

Auf **CORE-PKIWEB01** eine einfache, statische CPS-Seite ablegen (Inhalt durch die organisatorische Policy ersetzen):

```powershell
@'
<!DOCTYPE html>
<html lang="de"><head><meta charset="utf-8"><title>SecureOps PKI - CPS</title></head>
<body>
<h1>SecureOps Lab PKI - Certificate Practice Statement</h1>
<p>Betreiber, Geltungsbereich, Rollen, Antrags- und Freigabeprozess, Sperrung, Laufzeiten,
Schluesselschutz, Audit und Kontakt fuer Sperranfragen.</p>
</body></html>
'@ | Set-Content D:\PKI-Public\cps.html -Encoding UTF8
Invoke-WebRequest http://pki.secureops.local/pki/cps.html -UseBasicParsing | Select-Object StatusCode
```

#### 4.6 CSR an der Offline Root signieren
Ergebnis: `C:\PKI-Transfer\SecureOps-IssuingCA01.req`; die Installation ist bis zum Import des signierten CA-Zertifikats **ausstehend**. Kein Versuch, die Root per Netzwerk zu erreichen.

CSR auf kontrolliertem Medium zur Root übertragen. Auf **CORE-ROOT01** ausschließlich diesen CA-Antrag prüfen: Herkunft, Hash, Subject, RSA 4096, Basic Constraints `CA=TRUE, PathLength=0`, kein unerwarteter SAN. Keine fremden Anträge mit Root-CA-Rechten signieren.

```powershell
certutil.exe -dump C:\PKI-Transfer\SecureOps-IssuingCA01.req
certreq.exe -submit -config 'CORE-ROOT01\SecureOps-RootCA' `
    C:\PKI-Transfer\SecureOps-IssuingCA01.req
```

Die Standalone CA lässt den Antrag zunächst **pending**. Die ausgegebene Request-ID notieren und genau diesen Datensatz untersuchen. Nicht pauschal Auto-Issue auf der Root aktivieren. `Invoke-CertUtil` stammt aus Schritt 3.1 (in neuer Sitzung erneut definieren):

```powershell
$requestId = Read-Host 'Gepruefte Request-ID'
if ($requestId -notmatch '^[1-9][0-9]*$') { throw 'Ungueltige Request-ID' }
Invoke-CertUtil -view -restrict "RequestID=$requestId"
# Erst nach fachlicher Freigabe des angezeigten Antrags:
Invoke-CertUtil -resubmit $requestId
certreq.exe -retrieve -config 'CORE-ROOT01\SecureOps-RootCA' $requestId C:\PKI-Transfer\SecureOps-IssuingCA01.crt
if ($LASTEXITCODE -ne 0) { throw "certreq -retrieve fehlgeschlagen ($LASTEXITCODE)" }
Invoke-CertUtil -dump C:\PKI-Transfer\SecureOps-IssuingCA01.crt
# Aktuelle Root-CRL beilegen
Copy-Item "$env:SystemRoot\System32\CertSrv\CertEnroll\SecureOps-RootCA.crl" C:\PKI-Transfer -Force
```

Vor Weitergabe Laufzeit (max. 5 Jahre), Issuer, Signatur, CA-Basic-Constraints/PathLength 0, Certificate Policies mit CPS-URL, Key Usage und HTTP-AIA/CDP des **ausgestellten** Zertifikats prüfen. Root-Zertifikat, aktuelle Root-CRL und signiertes Issuing-Zertifikat zurückgeben, Root erneut sichern und offline herunterfahren.

## 5. Issuing CA abschließen und Vertrauen verteilen

Auf **CORE-CA01** die drei öffentlichen Dateien nach `C:\PKI-Transfer` importieren. Variablen und `Invoke-CertUtil` aus 4.1 verwenden (in neuer Sitzung erneut ausführen).

> Die Schritte 5.1–5.4 entsprechen dem optionalen Skript [Complete-IssuingCa.ps1](../Powershell/modul04/Complete-IssuingCa.ps1).

#### 5.1 Root-Fingerprint prüfen und Root vertrauen

```powershell
$expected = (Read-Host 'Unabhaengig bestaetigter Root-Thumbprint') -replace '\s', ''
$root = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 "$Transfer\SecureOps-RootCA.crt"
if ($root.Thumbprint -ne $expected.ToUpper()) { throw 'Root-Thumbprint stimmt NICHT ueberein - abbrechen!' }

Invoke-CertUtil -addstore -f Root "$Transfer\SecureOps-RootCA.crt"
Invoke-CertUtil -addstore -f Root "$Transfer\SecureOps-RootCA.crl"
```

#### 5.2 Kette prüfen und CA-Zertifikat installieren

```powershell
# Prueft Kette, AIA- und CDP-Abruf ueber HTTP; Fehler hier NICHT ignorieren
Invoke-CertUtil -verify -urlfetch "$Transfer\$CAName.crt"

Invoke-CertUtil -installcert "$Transfer\$CAName.crt"
Start-Service CertSvc
Get-Service CertSvc
```

#### 5.3 Veröffentlichung, Laufzeiten und Hardening konfigurieren

```powershell
Invoke-CertUtil -setreg CA\CRLPublicationURLs  "1:$CertEnroll\%3%8%9.crl\n2:$PkiUrl/%3%8%9.crl"
Invoke-CertUtil -setreg CA\CACertPublicationURLs "1:$CertEnroll\%1_%3%4.crt\n2:$PkiUrl/$CAName.crt"

# Basis-CRL 7 Tage, 1 Tag Ueberlappung, keine Delta-CRL
Invoke-CertUtil -setreg CA\CRLPeriod Days
Invoke-CertUtil -setreg CA\CRLPeriodUnits 7
Invoke-CertUtil -setreg CA\CRLOverlapPeriod Days
Invoke-CertUtil -setreg CA\CRLOverlapPeriodUnits 1
Invoke-CertUtil -setreg CA\CRLDeltaPeriodUnits 0

# Obergrenze fuer ausgestellte Endzertifikate (Vorlagen begrenzen zusaetzlich auf 1 Jahr)
Invoke-CertUtil -setreg CA\ValidityPeriod Years
Invoke-CertUtil -setreg CA\ValidityPeriodUnits 2

# Hardening
Invoke-CertUtil -setreg CA\AuditFilter 127
Invoke-CertUtil -setreg CA\InterfaceFlags +IF_ENFORCEENCRYPTICERTREQUEST
Invoke-CertUtil -setreg policy\EditFlags -EDITF_ATTRIBUTESUBJECTALTNAME2
auditpol.exe /set /subcategory:"{0CCE9221-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable

Restart-Service CertSvc
Invoke-CertUtil -crl
```

#### 5.4 Öffentliche Dateien exportieren und Ergebnis prüfen

```powershell
Invoke-CertUtil -ca.cert "$Transfer\$CAName.crt"
Copy-Item "$CertEnroll\$CAName.crl" $Transfer -Force

certutil.exe -getreg CA\CRLPublicationURLs
certutil.exe -getreg CA\CACertPublicationURLs
certutil.exe -getreg CA\InterfaceFlags
certutil.exe -getreg policy\EditFlags
certutil.exe -catemplates        # erwartet: leer, solange Abschnitt 6 noch nicht ausgefuehrt ist
certutil.exe -dump "$Transfer\$CAName.crl"
```

Ergebnis: Basis-CRL sieben Tage, Überlappung ein Tag, keine Delta-CRL, RPC-Paketverschlüsselung erforderlich, freie SAN-Requestattribute deaktiviert, CA-Auditfilter gesetzt, keine Standardvorlagen veröffentlicht.

#### 5.5 Publizieren und Vertrauen verteilen
`SecureOps-IssuingCA01.crt` und `SecureOps-IssuingCA01.crl` kontrolliert nach `D:\PKI-Public` auf **CORE-PKIWEB01** kopieren. Erst nach erfolgreichem HTTP-Abruf von einem Client Vorlagen veröffentlichen.

Mit Enterprise-Rechten auf der Issuing CA die **verifizierten** Zertifikate in AD veröffentlichen:

```powershell
Invoke-CertUtil -dspublish -f "$Transfer\SecureOps-RootCA.crt" RootCA
Invoke-CertUtil -dspublish -f "$Transfer\$CAName.crt" SubCA
Invoke-CertUtil -dspublish -f "$Transfer\$CAName.crt" NTAuthCA
```

NTAuth ist für die beabsichtigte AD-Authentifizierung relevant und keine pauschale Vertrauensliste für beliebige CAs. AD-Replikation abwarten. Root zusätzlich per Computer-GPO in **Trusted Root Certification Authorities**, Issuing-Zertifikat in **Intermediate Certification Authorities** verteilen. In einem reinen PowerShell-Lab kann ein bereits kontrolliert verteilter öffentlicher Root-/Issuing-Export je Zielmaschine mit `certutil -addstore Root ...` bzw. `certutil -addstore CA ...` importiert werden. Niemals Endzertifikate als Root vertrauen.

## 6. Angepasste Templates vollständig per PowerShell

### 6.1 Dedizierte Sicherheitsgruppen

Auf **CORE-CA01** das AD-Modul installieren; Gruppen auf einem beschreibbaren DC erzeugen. Beispielnamen des DCs an die tatsächliche Umgebung anpassen:

```powershell
Install-WindowsFeature RSAT-AD-PowerShell
Import-Module ActiveDirectory
$dc = 'DC01.secureops.local'
$groupPath = "CN=Users,$((Get-ADDomain -Server $dc).DistinguishedName)"
foreach ($name in 'GG_PKI_Computers', 'GG_PKI_WebServers', 'GG_PKI_CodeSigning',
    'GG_PKI_EFS', 'GG_PKI_EFSRecovery') {
    New-ADGroup -Name $name -GroupScope Global -GroupCategory Security `
        -Path $groupPath -Server $dc -ErrorAction Stop
}
# Nur konkrete, genehmigte Lab-Identitaeten aufnehmen, niemals Domain Users:
Add-ADGroupMember GG_PKI_Computers -Members (Get-ADComputer CORE-APP01 -Server $dc) -Server $dc
Add-ADGroupMember GG_PKI_WebServers -Members (Get-ADComputer CORE-WEB01 -Server $dc) -Server $dc
Add-ADGroupMember GG_PKI_CodeSigning -Members (Get-ADUser code.signer -Server $dc) -Server $dc
Add-ADGroupMember GG_PKI_EFS -Members (Get-ADUser efs.user -Server $dc) -Server $dc
Add-ADGroupMember GG_PKI_EFSRecovery -Members (Get-ADUser efs.recovery -Server $dc) -Server $dc
```

Neue Gruppenmitgliedschaften benötigen frische Anmeldetokens; bei Computerkonten gegebenenfalls Neustart. Signier- und Recovery-Konten nicht als normale Arbeitskonten verwenden.

### 6.2 Vorlagen erzeugen und prüfen

```powershell
.\New-CertificateTemplates.ps1 -DirectoryServer DC01.secureops.local
```

Das Skript erzeugt die Vorlagen zunächst **unveröffentlicht**. Es dupliziert gezielt die integrierten Vorlagen `Machine`, `WebServer`, `CodeSigning`, `EFS`, `EFSRecovery`, vergibt neue Forest-OIDs und ersetzt die sicherheitsrelevanten Einstellungen. Die Originalvorlagen bleiben unverändert.

| Neue Vorlage | EKU (ausschließlich) | Subject/SAN | Enrollment |
|-------------|---------------------|-------------|------------|
| SecureOpsComputer | Server Auth + Client Auth | DNS-SAN aus AD, kein frei gelieferter Subject | nur GG_PKI_Computers, Autoenrollment |
| SecureOpsWebServer | Server Auth | Subject/DNS-SAN im Antrag | nur GG_PKI_WebServers, **CA-Manager-Freigabe** |
| SecureOpsCodeSigning | Code Signing | Subject aus AD | nur GG_PKI_CodeSigning, **CA-Manager-Freigabe** |
| SecureOpsEFS | EFS | Subject aus AD | nur GG_PKI_EFS, Autoenrollment, Veröffentlichung in AD |
| SecureOpsEFSRecovery | EFS Recovery | Subject aus AD | nur GG_PKI_EFSRecovery, **CA-Manager-Freigabe** |

- Kein Any Purpose, keine leere EKU-Liste, kein Enrollment Agent, keine SubCA-Vorlage.
- Alle privaten Schlüssel **nicht exportierbar**, keine automatische Key-Archivierung. Die EFS-Vorlagen behalten CSP/Key Usage der kompatiblen Originale; ein Wechsel auf beliebige CNG-Provider ist kein sicherer Automatismus.
- Authenticated Users erhalten nur **Read**, nicht Enroll/Autoenroll. Ausschließlich jeweilige Gruppe erhält Enroll, nur Computer/EFS zusätzlich Autoenroll.
- SYSTEM, Domänen- und Enterprise-Administratoren behalten Verwaltungsrechte; die CA-Maschinenidentität erhält Read. Keine unprivilegierten Schreib-/Owner-/DACL-Rechte.
- Das Webserver-Template erlaubt absichtlich einen Antragsteller-SAN, aber **nur Server Auth und mit Freigabe**. DNS-Berechtigung unabhängig prüfen; nie fremde DC-/Admin-Namen freigeben. CA-weit bleibt `EDITF_ATTRIBUTESUBJECTALTNAME2` deaktiviert.

Vor Veröffentlichung auf dem angegebenen DC Attribute und ACL untersuchen; auf der CA nach Replikation `certutil -v -template SecureOpsComputer` usw. ausführen. Die SID-Sicherheitserweiterung nicht unterdrücken, keine schwachen Zertifikatzuordnungen einschalten.

```powershell
$config = (Get-ADRootDSE -Server $dc).configurationNamingContext
$base = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$config"
Get-ADObject -SearchBase $base -LDAPFilter '(cn=SecureOps*)' -Server $dc `
    -Properties pKIExtendedKeyUsage, msPKI-Certificate-Name-Flag, msPKI-Enrollment-Flag,
        msPKI-Private-Key-Flag, msPKI-Minimal-Key-Size, nTSecurityDescriptor |
    Format-List Name, pKIExtendedKeyUsage, msPKI-*, nTSecurityDescriptor

# Erst nach Replikation und Kontrolle, lokal auf CORE-CA01:
Import-Module ADCSAdministration
Get-CATemplate
foreach ($template in 'SecureOpsComputer', 'SecureOpsWebServer', 'SecureOpsCodeSigning',
    'SecureOpsEFS', 'SecureOpsEFSRecovery') {
    Add-CATemplate -Name $template -Force -ErrorAction Stop
}
Get-CATemplate
```

Erwartung: ausschließlich die fünf genehmigten Vorlagen. Unerwartete Altvorlagen gezielt mit `Remove-CATemplate -Name <Name>` entfernen, nicht ungeprüft alle Vorlagen löschen. CA-Service und AD-Replikation berücksichtigen; keine unbekannten Vorlagen überschreiben.

### 6.3 Autoenrollment auf Core-Clients

Bevorzugt per GPO **Certificate Services Client – Auto-Enrollment** unter Computer- bzw. Benutzerkonfiguration aktivieren (Erneuern, ausstehende Zertifikate aktualisieren, vorlagenbasierte Aktualisierung). Für das PowerShell-Lab sind die entsprechenden Policywerte lokal setzbar:

```powershell
# Erhoeht auf dem berechtigten Computer:
$machinePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment'
New-Item $machinePolicy -Force
New-ItemProperty $machinePolicy -Name AEPolicy -Value 7 -PropertyType DWord -Force
certutil.exe -pulse
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, Thumbprint, NotAfter, EnhancedKeyUsageList

# Als berechtigter EFS-Benutzer in dessen eigener Sitzung:
$userPolicy = 'HKCU:\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment'
New-Item $userPolicy -Force
New-ItemProperty $userPolicy -Name AEPolicy -Value 7 -PropertyType DWord -Force
certutil.exe -user -pulse
Get-ChildItem Cert:\CurrentUser\My | Select-Object Subject, Thumbprint, NotAfter, EnhancedKeyUsageList
```

Diese lokalen Werte ersetzen keine zentrale GPO-Verwaltung. Enrollment nutzt DCOM/RPC: TCP 135 und die tatsächlich konfigurierte dynamische RPC-Portspanne nur zwischen berechtigten Clients und CA freigeben. Nicht beliebig viele Ports für sämtliche Netze öffnen.

## 7. Webserver-Zertifikat beantragen, freigeben und installieren

Auf dem berechtigten **CORE-WEB01**, erhöhte Windows PowerShell. Ein Jahr, RSA 3072, nicht exportierbar; Subject/SAN müssen zur genehmigten Anwendung gehören:

```powershell
@'
[Version]
Signature="$Windows NT$"
[NewRequest]
Subject = "CN=app.secureops.local"
MachineKeySet = TRUE
KeyLength = 3072
KeyAlgorithm = RSA
ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
ProviderType = 12
KeySpec = 1
HashAlgorithm = sha256
Exportable = FALSE
RequestType = PKCS10
KeyUsage = 0xa0
[Extensions]
2.5.29.17 = "{text}"
_continue_ = "dns=app.secureops.local"
[RequestAttributes]
CertificateTemplate = SecureOpsWebServer
'@ | Set-Content C:\PKI-Transfer\web.inf -Encoding Ascii
certreq.exe -new C:\PKI-Transfer\web.inf C:\PKI-Transfer\web.req
certreq.exe -submit -config 'CORE-CA01.secureops.local\SecureOps-IssuingCA01' `
    C:\PKI-Transfer\web.req
```

Antrag bleibt pending. Zertifikatmanager prüft auf **CORE-CA01** Request-ID, Antragsteller, Vorlage, Subject und **alle SANs** sowie unabhängige DNS-/Dienstverantwortung. Prüfung und Freigabe protokollieren:

```powershell
# Invoke-CertUtil siehe Abschnitt 3.1
$requestId = Read-Host 'Gepruefte Request-ID'
if ($requestId -notmatch '^[1-9][0-9]*$') { throw 'Ungueltige Request-ID' }
Invoke-CertUtil -view -restrict "RequestID=$requestId"
# Nach Freigabe:
Invoke-CertUtil -resubmit $requestId
```

Zurück auf **demselben Antragsteller-Host** mit dortigem privaten Schlüssel:

```powershell
certreq.exe -retrieve -config 'CORE-CA01.secureops.local\SecureOps-IssuingCA01' `
    $requestId C:\PKI-Transfer\web.cer
certreq.exe -accept -machine C:\PKI-Transfer\web.cer
certutil.exe -verify -urlfetch C:\PKI-Transfer\web.cer
```

Zertifikat anhand des konkreten Thumbprints an den TLS-Dienst binden; nicht das erstbeste Zertifikat im Store auswählen. Anschließend tatsächlichen HTTPS-Endpunkt mit DNS-Namen, Vertrauenskette und Sperrprüfung testen.

## 8. Code Signing und EFS Recovery Agent

### Code Signing

In der eigenen Sitzung des dedizierten Signierkontos auf einem geschützten Core-Signierhost:

```powershell
$result = Get-Certificate -Template SecureOpsCodeSigning `
    -CertStoreLocation Cert:\CurrentUser\My
$result | Format-List *
```

Status **Pending** und Request-ID feststellen. Freigabe auf der CA wie in Abschnitt 7, danach als ursprüngliches Signierkonto `certreq -retrieve ...` und `certreq -accept -user ...` ausführen. Nicht vor Freigabe mit einem selbstsignierten Ersatz weiterarbeiten.

```powershell
$thumbprint = Read-Host 'Thumbprint des freigegebenen Code-Signing-Zertifikats'
$cert = Get-Item "Cert:\CurrentUser\My\$thumbprint" -ErrorAction Stop
if (-not $cert.HasPrivateKey -or
    '1.3.6.1.5.5.7.3.3' -notin @($cert.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId.Value })) {
    throw 'Kein nutzbares Code-Signing-Zertifikat'
}
Set-AuthenticodeSignature -FilePath C:\Scripts\MyScript.ps1 -Certificate $cert -HashAlgorithm SHA256
Get-AuthenticodeSignature C:\Scripts\MyScript.ps1
```

Öffentlichen Signier-**Endzertifikatexport**, nicht den privaten Schlüssel, nach genehmigter Publisher-Policy als Trusted Publisher verteilen. Root-/Issuing-Vertrauen allein bedeutet keine Publisher-Freigabe. Einen freigegebenen Zeitstempeldienst verwenden, wenn Signaturen über Zertifikatsablauf hinaus prüfbar sein sollen; internen Code nicht ungeprüft externen Diensten zuführen.

### EFS und EFS Recovery Agent (DRA)

Der Recovery Agent ist **kein Certificate Request Agent** und kein CA-Key-Recovery-Agent. Sein Schlüssel erlaubt die Wiederherstellung der entsprechend geschützten EFS-Dateien und benötigt besonders strengen Schutz.

```powershell
# Ausschliesslich als dediziertes Recovery-Konto auf gesichertem Core-Recovery-Host:
$result = Get-Certificate -Template SecureOpsEFSRecovery `
    -CertStoreLocation Cert:\CurrentUser\My
$result | Format-List *
```

Pending-ID wie oben prüfen/freigeben; Zertifikat **im ursprünglichen Benutzerkontext** abholen und akzeptieren. Thumbprint kontrollieren, dann nur das öffentliche DRA-Zertifikat exportieren:

```powershell
$thumbprint = Read-Host 'Thumbprint des EFS-Recovery-Zertifikats'
$dra = Get-Item "Cert:\CurrentUser\My\$thumbprint" -ErrorAction Stop
if ('1.3.6.1.4.1.311.10.3.4.1' -notin @($dra.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId.Value })) {
    throw 'Kein EFS-Recovery-Zertifikat'
}
Export-Certificate -Cert $dra -FilePath C:\PKI-Transfer\EFS-Recovery.cer
```

**DRA-Policy ist ein eigener, zwingender Schritt**: Für ein isoliertes lokales Core-Lab das geprüfte öffentliche DRA-Zertifikat als Administrator auf dem NTFS-Testclient in den lokalen Gruppenrichtlinien-Zertifikatspeicher für EFS importieren. Vorhandene Domänenrichtlinien können lokale Einstellungen übersteuern; nur auf einem dafür vorgesehenen Testclient ausführen:

```powershell
certutil.exe -GroupPolicy -f -addstore EFS C:\PKI-Transfer\EFS-Recovery.cer
if ($LASTEXITCODE -ne 0) { throw 'DRA-Policy-Import fehlgeschlagen' }
certutil.exe -GroupPolicy -store EFS
gpupdate.exe /target:computer /force
```

Danach mit einer **neu** verschlüsselten Testdatei und `cipher /c` prüfen, dass das Zertifikat ausdrücklich unter den **Recovery Certificates** erscheint. Fehlt es dort, den Versuch abbrechen und die wirksame Recovery-Policy korrigieren. `cipher /adduser` ist kein Ersatz: es fügt zusätzliche EFS-Benutzer hinzu, keinen Recovery Agent. Die lokale Store-Änderung ersetzt keine domänenweite Recovery-Policy.

Für flächendeckenden Betrieb vor der ersten produktiven EFS-Verschlüsselung eine genehmigte **File System / Encrypting File System Data Recovery Agent Policy** per Computer-GPO ausrollen. Die oben stehenden Skripte konfigurieren diese GPO **nicht**. Es gibt dafür kein direktes `Set-GPRegistryValue`-Äquivalent, das bloß einen Zertifikat-Thumbprint setzt. Auf Core-only-Administrationswegen eine vorab validierte GPO-Sicherung mit DRA-Policy per `Import-GPO`/`New-GPLink` einspielen; ohne eine solche Sicherung ist die domänenweite EFS-Einführung **nicht abgeschlossen**. Nicht auf `cipher /r` als Enterprise-Template-Ersatz ausweichen: es erzeugt selbstsignierte Recovery-Zertifikate.

**Wichtige Grenze der nicht exportierbaren Schlüssel:** Ein CA-Datenbankbackup sichert keine Benutzer-/DRA-Schlüssel. Für dieses Lab den kompletten gesicherten Recovery-Host einschließlich Profil/DPAPI schützen und dessen Wiederherstellung testen; Kopieren einer einzelnen Schlüsseldatei genügt nicht. Vor Produktion zwischen HSM-/Recovery-Host-Backup, genehmigter exportierbarer DRA-Sondervorlage mit Offline-PFX oder einer separat entworfenen Key-Archiving-/KRA-Lösung entscheiden. Nicht heimlich Exportierbarkeit für alle EFS-/Signierschlüssel aktivieren.

EFS-Test erst auf einem dafür vorgesehenen NTFS-Client und nach Recovery-Vorsorge:

1. Als EFS-Benutzer ein Zertifikat aus `SecureOpsEFS` erhalten; Inhalt schreiben, mit `cipher /e` verschlüsseln, `cipher /c` prüfen.
2. DRA unter den Recovery-Zertifikaten der Datei nachweisen und dokumentieren, welche Identität tatsächlich entschlüsseln kann.
3. Zugriff durch einen nicht berechtigten Benutzer muss scheitern.
4. Mit separatem Recovery-Konto samt wiederhergestelltem privaten Schlüssel eine **Dateikopie** entschlüsseln; Inhalt vergleichen.
5. Nach DRA-Erneuerung bestehende Dateien/Recovery-Felder aktualisieren und erneut prüfen. Alte Schlüssel so lange geschützt erhalten, wie noch Dateien damit entschlüsselt werden müssen.

Wenn EFS auf der gewählten Server-Core-Installation/Datenträgerkonfiguration nicht verfügbar ist, nur Enrollment und Zertifikatprofil testen und den Dateiversuch auf einem unterstützten Windows-NTFS-Client durchführen. Die CA-Rollen bleiben Server Core.

## 9. Hardening-Checkliste

| Bereich | Konkrete Maßnahme / Prüfung |
|---------|-----------------------------|
| Tier 0 | CAs, Sicherungen, CA-Admins und Hypervisor isolieren; Administration nur von PAW/Jump Host; kein Browsing, Mail oder Entwicklertooling auf CAs |
| Offline Root | Kein Netzwerk, kein Domänenkonto, Vier-Augen-Zeremonie, Medienkontrolle, getrennte verschlüsselte Backups; geplante CRL-Zeremonien |
| Betriebssystem | Aktuelle Windows-Server-2025-Security-Baseline vor AD-CS-Rollout testen; Defender, BitLocker, Secure Boot/TPM, Patch- und Zeitkonzept |
| Rollen/Protokolle | Nur CA-Rolle; keine Enrollment-Webdienste. Falls später nötig: separates Design mit HTTPS, EPA und NTLM-Reduktion statt ungeprüfter Installation |
| Netzwerk | Host-Firewall aktiv; Enrollment-RPC nur für berechtigte Netze, Management nur PAW; DNS/AD/NTP/CRL gezielt erreichbar; keine offene All-Netze-RPC-Regel |
| CA-Policy | `IF_ENFORCEENCRYPTICERTREQUEST` gesetzt; `EDITF_ATTRIBUTESUBJECTALTNAME2` aus; keine ungeprüften Policy-Module |
| Templates | Nur fünf freigegebene Vorlagen; eingeschränkte Enroll-/Autoenroll-ACLs; kein Any Purpose, keine unprivilegierten Template-Schreibrechte |
| Identitätsbindung | Aktuelle DC-/CA-Updates, starke Zertifikatzuordnung und SID-Sicherheitserweiterung beibehalten; keine Kompatibilitäts-Bypässe |
| Trennung | CA-Verwalter und Zertifikatmanager getrennt delegieren; Requester genehmigt eigene Anträge nicht; strikte Rollentrennung erst mit Notfall-/Recovery-Test aktivieren |
| Schlüssel | Produktiv HSM für CA-/Signierschlüssel erwägen, CSP/KSP-Kompatibilität prüfen; Recovery-Konzept vor „nicht exportierbar“ |
| Audit | CA-Auditfilter **und** Windows Advanced Audit Policy „Certification Services“ Success/Failure aktivieren; zentrale geschützte Logs |
| Monitoring | CRL NextUpdate, HTTP-Inhalt und Signatur, CA-/Vorlagenänderungen, Pending Queue, Zertifikatsablauf und Backupstatus alarmieren |

Der CA-Auditfilter allein aktiviert keine Windows-Audit-Unterkategorie. Sprachunabhängiges Lab-Beispiel:

```powershell
auditpol.exe /set /subcategory:"{0CCE9221-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable
auditpol.exe /get /subcategory:"{0CCE9221-69AE-11D9-BED3-505054503030}"
certutil.exe -getreg CA\AuditFilter
certutil.exe -getreg CA\InterfaceFlags
certutil.exe -getreg policy\EditFlags
```

Ereignisse unter anderem 4886/4887/4888/4889 (Anträge), 4870 (Sperrung), 4890/4891 (CA-Konfigurationsänderungen) und 4898–4900 (Vorlagen) gemäß aktiviertem Auditumfang auswerten. Vorlagenänderungen in AD zusätzlich über Directory Service Changes und passende SACL überwachen.

BSI-Zuordnung (Edition 2023): **SYS.1.1**, **SYS.1.2.3 Windows Server** (A5, A7, A8), **APP.2.2**, **CON.1 Kryptokonzept**, **CON.3 Datensicherungskonzept**, **ORP.4 Identitäts- und Berechtigungsmanagement**, **OPS.1.1.5 Protokollierung**, **NET.1.1** und **TR-02102-1**. SYS.1.2.2 betrifft nur noch Windows Server 2012. Keine Windows-2025-Zertifizierung aus einem Baustein ableiten. Geprüfte Direktlinks siehe [Referenzen](Referenzen.md#baustein-pdfs-edition-2023-geprüft).

## 10. Betrieb: CRLs, Sperren, Backup und Erneuerung

### CRLs regelmäßig erneuern und publizieren

Issuing CA: täglich neue Basis-CRL erzeugen und über kontrollierten Job auf den HTTP-Host übertragen, bei Sperrungen sofort. Root: spätestens nach 20 Wochen eine neue CRL-Zeremonie planen, nicht erst kurz vor Ende der 26 Wochen. **NextUpdate** der tatsächlich publizierten Datei ist maßgeblich; Überlappung ersetzt keinen Überwachungsalarm.

```powershell
# Invoke-CertUtil siehe Abschnitt 3.1
Invoke-CertUtil -crl
certutil.exe -dump C:\Windows\System32\CertSrv\CertEnroll\SecureOps-IssuingCA01.crl
# Beispiel: 1 = Key Compromise; nur nach gepruefter Incident-Entscheidung:
$serial = Read-Host 'Gepruefte Seriennummer des zu sperrenden Zertifikats'
Invoke-CertUtil -revoke $serial 1
Invoke-CertUtil -crl
```

Neue CRL zuerst in Staging prüfen, dann atomar veröffentlichen; nicht per Direktkopie eine gerade gelesene Datei überschreiben. Für Routinejobs eingeschränkte Transferrechte, weder Domain Admin noch CA-Schlüssel verwenden. Ein erfolgreicher CA-Aufruf ohne erfolgreiche HTTP-Veröffentlichung ist **kein** erfolgreicher CRL-Job.

### Backups und Notfallvorsorge

Auf jeder CA separat, Ziel vorab ausschließlich für SYSTEM/CA-Backup-Verantwortliche berechtigen. Im Lab ist `F:\CA-Backup` ein dediziertes, geschütztes Ziel, nicht das Webverzeichnis:

```powershell
# Invoke-CertUtil siehe Abschnitt 3.1
New-Item F:\CA-Backup -ItemType Directory -Force
Invoke-CertUtil -backupDB F:\CA-Backup
# Interaktive Kennwortabfrage; Kennwort NICHT als Befehlsargument/Quelltext speichern:
Invoke-CertUtil -backupKey F:\CA-Backup
reg.exe export HKLM\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration F:\CA-Backup\CA-Configuration.reg /y
if ($LASTEXITCODE -ne 0) { throw "reg export fehlgeschlagen ($LASTEXITCODE)" }
Copy-Item C:\Windows\CAPolicy.inf F:\CA-Backup
```

CA-Zertifikate, CRLs, Konfiguration, Datenbank/Logs, Template-Definitionen samt ACL/OID, GPOs und Betriebshandbuch erfassen. Vorlagen liegen in **AD**, nicht allein in der CA-Datenbank. Zusätzlich unterstütztes System-/Bare-Metal-Backup planen; HSM-Keys nach Herstellerverfahren sichern. Restore in isolierter Umgebung testen, keine zweite aktive CA mit derselben Identität im Produktionsnetz starten. EFS-/DRA-Benutzerschlüssel separat behandeln (Abschnitt 8).

CA-Erneuerung **nicht** durch erneuten Aufruf der Installationsskripte. Das Lab verwendet stabile AIA-Dateinamen für die erste CA-Generation. Vor CA-Key-Rollover versionsabhängige AIA-Dateinamen (`%4`) planen, neue und alte CA-Zertifikate parallel vorhalten und alte CDP-/AIA-URLs bis zum Ende ihrer Abhängigkeiten bedienen. Nicht einfach die bestehenden `.crt`-Dateien durch eine neue Schlüsselgeneration ersetzen.

## 11. Abnahme und Negativtests

Auf einem frischen, nicht auf den CA-Cache angewiesenen berechtigten Core-Client:

```powershell
Resolve-DnsName pki.secureops.local
Invoke-WebRequest http://pki.secureops.local/pki/SecureOps-RootCA.crl -UseBasicParsing
Invoke-WebRequest http://pki.secureops.local/pki/SecureOps-IssuingCA01.crl -UseBasicParsing
certutil.exe -verify -urlfetch C:\PKI-Transfer\web.cer
Get-ChildItem Cert:\LocalMachine\My | Format-List Subject, Thumbprint, HasPrivateKey, EnhancedKeyUsageList
```

- [ ] Root offline; untergeordnete CA-Kette Root → Issuing → Endzertifikat korrekt; Issuing `PathLength=0`.
- [ ] AIA/CDP per anonymem HTTP erreichbar; heruntergeladene CRLs signaturgültig, `NextUpdate` überwacht. Test auch ohne vorhandenen CRL-Cache auf isoliertem Testclient.
- [ ] Computer-Enroll als Maschinenidentität erfolgreich, DNS-SAN aus AD; Benutzer-/Maschinenstores nicht verwechselt.
- [ ] Nichtmitglied kann **keine** der Vorlagen enrollen; Template-DACL gibt ihm keine Schreibrechte.
- [ ] Webserver-, Code-Signing- und Recovery-Anträge bleiben ohne Freigabe pending; falsche SANs werden abgelehnt.
- [ ] Webserver-Zertifikat besitzt **kein Client Auth**, Code Signing kein EFS und kein Client Auth; Recovery nur Recovery-EKU.
- [ ] Privater Schlüssel vorhanden, nicht exportierbar; negative PFX-Exportprüfung nur auf Testkonten. Nachweis der getrennten Schlüsselwiederherstellung.
- [ ] Kontrolliert gesperrtes Testzertifikat schlägt nach CRL-Veröffentlichung und Cacheablauf bei `certutil -verify -urlfetch` fehl.
- [ ] EFS-Zertifikat aus eigener Vorlage; Wiederherstellung einer Testdatei als Recovery-Identität erfolgreich; flächendeckender DRA-GPO-Rollout separat nachgewiesen.
- [ ] CA-Backup und isolierter Restore erfolgreich; Alarmierung bei ausgefallenem HTTP-Publikationspunkt erprobt.

### Lokale Skripttests (ohne CA-Installation)

Ausführen in **Windows PowerShell 5.1** mit dem integrierten Pester 3.4 (die Tests verwenden die Pester-3/4-Syntax; unter PowerShell 7 bzw. Pester 5 nicht ausführen):

```powershell
powershell.exe -NoProfile -Command "Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester .\Powershell\modul04\Tests\Pki.Tests.ps1"
```

Die Tests prüfen Parser, Native-Exitcode-Behandlung und gemockte CA-Publikations-/Hardeningbefehle. **Kein Ersatz** für die oben genannten AD-CS-/AD-/IIS-/EFS-Integrationstests auf Windows Server 2025 Core.

## 12. Weiterführende Quellen

- [Microsoft: PKI design considerations](https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/pki-design-considerations)
- [Microsoft: Install-AdcsCertificationAuthority](https://learn.microsoft.com/en-us/powershell/module/adcsdeployment/install-adcscertificationauthority)
- [Microsoft: Certificate template concepts](https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/certificate-template-concepts)
- [Microsoft: certutil](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certutil)
- [Microsoft: certreq](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certreq_1)
- [Microsoft: cipher](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cipher)
- [BSI CON.1 Kryptokonzept (PDF, Edition 2023)](https://www.bsi.bund.de/SharedDocs/Downloads/DE/BSI/Grundschutz/IT-GS-Kompendium_Einzel_PDFs_2023/03_CON_Konzepte_und_Vorgehensweisen/CON_1_Kryptokonzept_Edition_2023.pdf?__blob=publicationFile&v=3)
- [BSI SYS.1.2.3 Windows Server (PDF, Edition 2023)](https://www.bsi.bund.de/SharedDocs/Downloads/DE/BSI/Grundschutz/IT-GS-Kompendium_Einzel_PDFs_2023/07_SYS_IT_Systeme/SYS_1_2_3_Windows_Server_Edition_2023.pdf?__blob=publicationFile&v=5)
- [BSI TR-02102 Kryptographische Verfahren](https://www.bsi.bund.de/DE/Themen/Unternehmen-und-Organisationen/Standards-und-Zertifizierung/Technische-Richtlinien/TR-nach-Thema-sortiert/tr02102/tr02102_node.html)
- [Alle BSI-Referenzen mit Prüfstatus](Referenzen.md#deutsche-sicherheitsressourcen-bsi)
