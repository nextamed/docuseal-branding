# DocuSeal-Overlay: Arbeitsvertrag

Dieses Repo erweitert eine gepinnte DocuSeal-Version durch Branding und wenige
View-Overrides. README.md dokumentiert die Overrides, den Upstream-Abgleich und
den bisherigen Betriebsweg. ai/knowledge/README.md erschließt Stand und Erkenntnisse.

## Entwicklung

Vor einer Änderung Dockerfile und die betroffenen Overrides lesen. Ganze
Upstream-Dateien beim Versionswechsel gegen den neuen Tag vergleichen. Keine
unabhängige Anwendung oder neue Signaturlogik aus dem Overlay machen.
`ai/skills/docuseal-branding-develop/SKILL.md` führt durch die Prüfung.

Attribution, vorhandene Lizenzangaben und Sicherheitsmechanismen erhalten.
Die rechtliche Bewertung einer Formulierung ist nicht durch einen UI-Test belegt.
Öffentliche Dateien enthalten keine privaten Betriebszugänge oder Beispieldaten.

## Prüfen und betreiben

`node --test tests/overlay.test.mjs` prüft die tatsächliche JavaScript-Ergänzung
in isolierten DOM-Fixtures und wichtige Overlay-Grenzen. Der vorhandene
Image-Build bleibt erforderlich; sichtbare Empfängeroberflächen brauchen bei
betroffenen Änderungen einen separaten Test mit eigenen Testdaten.

Ein Push auf main veröffentlicht ein Image. Er beweist weder den Einsatz in
Coolify noch einen funktionierenden Signaturvorgang. Betriebsweg:
`ai/skills/docuseal-branding-operate/SKILL.md`. Keine echten Signaturanfragen
oder Nachrichten nur zur Repo-Abnahme auslösen.

## Abschluss

Auf Feature-Branch arbeiten, gezielten PR mit Prüfergebnissen erstellen.
Neue Erkenntnisse in ai/knowledge/README.md; Upstream-/Override-Fakten direkt
im README korrigieren. Vorgängerimage und Datenkompatibilität vor einer
autorisierten Rücknahme prüfen, keine Rücknahme auf ein bewegliches latest versprechen.

<!-- repo-standard:begin -->
## Repository standard

Use [the shared core](ai/standard/core.md) and [the overlay profile](ai/standard/profile.md) for applicable work.
[Repository configuration](ai/repo-standard.json) lists the local checks, knowledge sources, skills, and deployment boundaries. Existing repository-specific rules remain in force.

Load the relevant canonical skill when developing or operating this repository:
- [docuseal-branding-develop](ai/skills/docuseal-branding-develop/SKILL.md)
- [docuseal-branding-operate](ai/skills/docuseal-branding-operate/SKILL.md)
<!-- repo-standard:end -->
