---
name: docuseal-branding-develop
description: Ändere Branding oder eine DocuSeal-Upstream-Version und prüfe die betroffenen Overrides, Signatur-UI-Hooks und Attribution dieses Repos. Verwenden für Entwicklung und Update-Review des Overlays.
---

# Overlay entwickeln

1. AGENTS.md, Dockerfile und die Update-Checkliste in README.md lesen.
2. Override-Ziel und Upstream-Tag belegen. Bei Full-File-Overrides die neue
   Originaldatei vergleichen, bestehende lokale Blöcke gezielt übertragen.
3. Nur betroffene Assets/Views ändern. Rollenbezogene Buttonmarker und
   vorhandene Sicherheits-/Attributionspfade erhalten. Keine echten Submissions.
4. `node --test tests/overlay.test.mjs` ausführen. Die Tests führen den lokalen
   JavaScript-Block aus; sie ersetzen keine Rails- oder Browserintegration.
5. Vorhandenen Build im PR prüfen. Bei visueller/Signaturänderung Testoberflächen
   gemäß README mit Testdaten aufrufen und tatsächliche Ergebnisse festhalten.
6. Neue Version/Override-Fakten im README, neue Erkenntnisse im Wissensindex
   aktualisieren. Gezielten PR erstellen, Prüflücken ausdrücklich nennen.
