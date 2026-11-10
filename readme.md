# Microsoft Windows 2025 Server SecureOps

**Trainer:** Michael Lindner

---

## Kursübersicht

Dieser 4-tägige Kurs vermittelt den Teilnehmern die notwendigen Kenntnisse zur sicheren Installation, Konfiguration und Härtung von Windows Server 2025 in Unternehmensumgebungen.

### Kursziele

- Sichere Installation von Windows Server 2025 (Core Edition bevorzugt)
- Implementierung von Microsoft Security Baselines
- Aufbau einer sicheren Infrastruktur mit Jump Servern
- Einrichtung einer separaten Admin-Domäne für größere Umgebungen
- PowerShell-Skript-Signierung und Just Enough Administration (JEA)
- Desired State Configuration (DSC) für konsistente Serverkonfiguration
- Zweistufige PKI auf Server Core: Offline Root CA, Enterprise Issuing CA und angepasste Zertifikatvorlagen

### Tagesübersicht

| Tag | Thema | Beschreibung |
|-----|-------|--------------|
| 1 | [Umgebung aufbauen](Unterlagen/Tag1-Umgebung-aufbauen.md) | Windows Server 2025 Installation, Grundkonfiguration, Datenbanklaufwerke |
| 2 | [Jump Server](Unterlagen/Tag2-Jump-Server.md) | PAW-Konzept, Security Baselines, Netzwerksegmentierung |
| 3 | [Admin Domain](Unterlagen/Tag3-Admin-Domain.md) | ESAE-Architektur, AGDLP-Prinzip, Tier-Modell |
| 4 | [PowerShell Security](Unterlagen/Tag4-PowerShell-Security.md) | JEA, DSC, Skript-Signierung |

### Zusatzmodul PKI (nach Tag 3 / als Grundlage für Tag 4)

[PKI vollständig per PowerShell auf Server Core](Unterlagen/PKI-Server-Core.md): Offline Root CA und Enterprise Issuing CA, HTTP-AIA/CDP, angepasste Templates für Computer, Webserver, Code Signing, EFS und EFS Recovery Agent. Einschließlich Hardening, Freigaben, CRL-Betrieb, Backup und Abnahmetests. Die passenden Skripte liegen in [Powershell/modul04](Powershell/modul04/).

### Wichtige Sicherheitsreferenzen

- [Microsoft Security Baselines](https://learn.microsoft.com/de-de/windows/security/operating-system-security/device-management/windows-security-configuration-framework/windows-security-baselines)
- [CVE - Common Vulnerabilities and Exposures](https://cve.mitre.org/)
- [ENISA - European Union Agency for Cybersecurity](https://www.enisa.europa.eu/)
- [BSI IT-Grundschutz](https://www.bsi.bund.de/DE/Themen/Unternehmen-und-Organisationen/Standards-und-Zertifizierung/IT-Grundschutz/it-grundschutz_node.html)
- [CERT-Bund Warn- und Informationsdienst](https://wid.cert-bund.de/portal/wid/shortinfo)

Geprüfte BSI-Links (Stand 10.11.2026) inkl. Baustein-PDFs: [Referenzen](Unterlagen/Referenzen.md#deutsche-sicherheitsressourcen-bsi).

---

## Ordnerstruktur

```
├── Unterlagen/          # Schulungsunterlagen pro Tag
├── Powershell/          # PowerShell-Skripte und Module
│   ├── modul01/         # Grundlegende Skripte
│   ├── modul02/         # DSC-Konfigurationen
│   ├── modul03/         # JEA-Konfigurationen
│   └── modul04/         # Server-Core-PKI und Vorlagen
└── readme.md            # Diese Datei
```