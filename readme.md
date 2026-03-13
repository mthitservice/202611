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

### Tagesübersicht

| Tag | Thema | Beschreibung |
|-----|-------|--------------|
| 1 | [Umgebung aufbauen](Unterlagen/Tag1-Umgebung-aufbauen.md) | Windows Server 2025 Installation, Grundkonfiguration, Datenbanklaufwerke |
| 2 | [Jump Server](Unterlagen/Tag2-Jump-Server.md) | PAW-Konzept, Security Baselines, Netzwerksegmentierung |
| 3 | [Admin Domain](Unterlagen/Tag3-Admin-Domain.md) | ESAE-Architektur, AGDLP-Prinzip, Tier-Modell |
| 4 | [PowerShell Security](Unterlagen/Tag4-PowerShell-Security.md) | JEA, DSC, Skript-Signierung |

### Wichtige Sicherheitsreferenzen

- [Microsoft Security Baselines](https://learn.microsoft.com/de-de/windows/security/operating-system-security/device-management/windows-security-configuration-framework/windows-security-baselines)
- [CVE - Common Vulnerabilities and Exposures](https://cve.mitre.org/)
- [ENISA - European Union Agency for Cybersecurity](https://www.enisa.europa.eu/)
- [BSI IT-Grundschutz](https://www.bsi.bund.de/DE/Themen/Unternehmen-und-Organisationen/Standards-und-Zertifizierung/IT-Grundschutz/it-grundschutz_node.html)

---

## Ordnerstruktur

```
├── Unterlagen/          # Schulungsunterlagen pro Tag
├── Powershell/          # PowerShell-Skripte und Module
│   ├── modul01/         # Grundlegende Skripte
│   ├── modul02/         # DSC-Konfigurationen
│   └── modul03/         # JEA-Konfigurationen
└── readme.md            # Diese Datei
```