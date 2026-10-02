---
name: docuseal-branding-operate
description: Diagnostiziere ein eingesetztes DocuSeal-Branding-Image oder bereite ein autorisiertes Update und dessen Rücknahme vor. Verwenden für Betrieb des Overlays, ohne aus einem Build eine erfolgreiche Signatur abzuleiten.
---

# Overlay betreiben

1. AGENTS.md und README-Abschnitte Build, Update und Coolify-Cutover lesen.
2. Laufenden Dienst, Image-Digest und Upstream-Version lesend feststellen.
   Repo-Pin, Registry-Tag und laufendes Image als getrennte Zustände erfassen.
3. Bei Fehlern betroffene Oberfläche/Hook eingrenzen, alte und neue Version
   vergleichen. Keine Signaturen, Nachrichten oder Vertragsdaten zu Testzwecken verändern.
4. Ein beauftragtes Update mit passender Daten-/Volumesicherung, geprüftem
   Kandidaten und konkretem vorherigen Digest vorbereiten. Vor Rücknahme mögliche
   Upstream-Datenmigration prüfen; ein Image-Wechsel allein garantiert keine Rücknahme.
5. Nur den autorisierten Eingriff ausführen. Anschließend Gesundheit und
   betroffene UI-Funktion separat mit Testdaten nachweisen.
6. Ergebnis mit Zeitpunkt/Version/Beleg im Wissensindex festhalten. README-
   Checklisten gelten als Anleitung, nicht als Nachweis bereits ausgeführter Schritte.
