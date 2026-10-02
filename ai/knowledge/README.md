# Stand, Entscheidungen und Erkenntnisse

## Quellen

- Aktueller Code-/Upstreamstand: Dockerfile und README.md.
- Betriebsanleitung: README.md, Update-Prozess und Coolify-Cutover.
- Tatsächlicher Betriebsstand: vor Eingriff am Dienst lesen; hier kein Live-Nachweis.

## Entscheidung · 2026-10-02 · Repo-Standard

Gemeinsamen Kern mit Overlay-Profil einführen; vorhandenes Docker-Build bleibt
die Lieferprüfung. Neue Offline-Fixtures prüfen den echten eingebetteten JS-Block.
Beleg: AGENTS.md, ai/repo-standard.json und tests/overlay.test.mjs in diesem Change.

## Erkenntnis · 2026-10-02 · Image-Rückweg

README nennt beim Rückweg `docuseal/docuseal:latest`. Das ist ein veränderlicher
Tag und kein belegter Vorgängerstand. Für künftige Betriebsänderungen vorherigen
Digest festhalten und Datenkompatibilität prüfen. Beleg: README, Abschnitt Rollback;
Dockerfile pinnt demgegenüber einen konkreten Upstream. Keine Live-Rücknahme getestet.

## Offene Nachweise

Rails-Integration, visuelle Empfängeroberflächen und Wiederherstellung bei einem
Upstreamwechsel bleiben konkrete Betriebsprüfungen mit Testdaten. Ein grüner
Offlinecheck schließt diese Punkte nicht ab.
