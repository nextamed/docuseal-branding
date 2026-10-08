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

## Erkenntnis · 2026-10-07 · Upstream 3.3.1

`submit_form/show.html.erb` übergibt dem Formular ab 3.3.1 neue Locals
(`prefill_signature`, `prefill_initials`, `current_user_data`); ein alter
Full-File-Override hätte die Signaturseite gebrochen. Tab-Titel der
Empfängerseiten kommen jetzt aus `shared/_html_title.html.erb`, das Overlay
überschreibt nur diesen Partial. Neue Migration `otp_challenges` ist additiv;
vor einer Rücknahme auf 3.2.4 trotzdem Digest und Daten prüfen. Beleg: Diff
der Tags 3.2.4/3.3.1, ERB-Compile mit ActionView 8.1, Overlay-Tests. Kein
Image-Build und kein Browser-Test in dieser Umgebung.

## Erkenntnis · 2026-10-07 · Buttonlösung, Widerrufsfunktion, Protokoll

BGH I ZR 159/24 (9.10.2025): Online geschlossener Maklervertrag ohne
ausdrückliche Bestätigung der Zahlungspflicht am Abschluss-Button ist endgültig
unwirksam. § 356a BGB (seit 19.6.2026) verlangt bei Fernabsatzverträgen über
eine Online-Benutzeroberfläche eine Widerrufsfunktion („Vertrag widerrufen",
dann „Widerruf bestätigen", Eingangsbestätigung auf dauerhaftem Datenträger).
DocuSeal 3.3.1 hat keine Widerrufsfunktion, nur „Ablehnen" vor der Signatur.
Der Audit-Trail druckt Feldwerte des Unterzeichners (Account-Config
`with_audit_values`, Standard an), auch schreibgeschützte Felder mit
Standardwert (`merge_default_values`). Ein solches Feld ist der Weg ohne
Signaturlogik, die Schaltflächenbeschriftung ins Protokoll zu bringen. Die
rechtliche Bewertung ist damit nicht belegt.

## Erkenntnis · 2026-10-07 · Lücken der Buttonlösung, Klick-Screenshot

Code-Analyse 3.3.1 mit Gegenprüfung: Der Vorgang lässt sich auch über den
Kopfzeilen-Button „Abschließen", über „Einreichen" im Handy-Querformat, in
zwölf weiteren Browsersprachen und über das Einladungsformular abschließen;
das Overlay beschriftet dort nichts um. Ein Klick-Screenshot ist keine
Lösung: Browser erlauben ohne Freigabedialog nur eine Nachzeichnung des DOM,
ins Protokoll käme sie nur über ein sichtbares, nicht schreibgeschütztes
Bildfeld und ein angehaltenes Absenden (neue Signaturlogik). Ungültige
Bild-UUIDs lassen die Audit-Trail-Erzeugung nach dem Abschluss scheitern.
§ 25 TDDDG ist wahrscheinlich einschlägig. Belastbarer: Lücken schließen,
serverseitiges Protokollfeld, Referenz-Testläufe pro Template- und
Overlay-Version. Beleg: Workflow-Analyse mit Code-Stellen in form.vue,
submit_values.rb, generate_audit_trail.rb; kein Browser- oder Live-Test.

## Erkenntnis · 2026-10-07 · Hinweisseite im Template

Eine feste Hinweisseite lässt sich ohne Code anlegen: ins Vertrags-PDF
zusammenführen (Builder „Bearbeiten" > „Mit vorherigem zusammenführen"), dann
deckt der Dokument-Hash im Prüfprotokoll sie ab. Schreibgeschützte Textfelder
mit Standardwert füllt der Server beim Abschluss; `{{date}}`/`{{time}}` stehen
vorher wörtlich im Formular, `{{id}}` ist schon aufgelöst. Die Beschreibung
des Unterschriftsfelds steht auf jedem Gerät direkt über Zeichenfeld und
Schaltfläche. Der Standardtext der Schaltfläche bricht auch bei 560 px Breite
auf zwei Zeilen um. Eine vorformulierte Tatsachenbestätigung des Kunden ist
nach § 309 Nr. 12 b BGB voraussichtlich unwirksam, die Seite informiert daher
nur. Beleg: Workflow-Analyse 3.3.1 (builder.vue, submit_values.rb,
generate_audit_trail.rb), Render mit kompiliertem Form-CSS; kein Live-Test.

## Erkenntnis · 2026-10-08 · Doppelte Vorgänge durch „Erneut einreichen"

Laufender Dienst: Image `ghcr.io/nextamed/docuseal-branding:latest` (main,
Upstream 3.2.4; PR 9 nicht gemergt). Die Abschlussseite eines über den
Freigabelink gestarteten Vorgangs zeigt bis 3 Tage nach Abschluss „Erneut
einreichen" (`submit_form/completed.html.erb:47`, `RESUBMIT_TTL`). Ein Klick
legt über `StartFormResubmitController#update` einen neuen Vorgang mit Name,
E-Mail, Telefon und Metadaten der Person an; es geht keine Einladung raus,
nur Webhook `submission.created`. Abschalten: Kontoeinstellung „Erneutes
Einreichen abgeschlossener Formulare zulassen" (`allow_to_resubmit`).
Beleg: Container-Logs vom 07./08.10. (Resubmit-PUT, danach neuer Submitter
ohne Abschluss), Code 3.2.4. Datenbank nicht eingesehen. Nebenbefund: die
ok_manage-Signaturtools melden fehlende `DOCUSEAL_APP_URL`/`DOCUSEAL_API_TOKEN`.

## Erkenntnis · 2026-10-08 · Was DocuSeal zu Unterzeichnern protokolliert

DocuSeal 3.2.4 hält Einladungsmails (`send_email`), Öffnen/Klicks und
Formularschritte als Ereignisse fest, nicht aber die Kopie-Mail nach dem
Abschluss und keine Downloads auf der Abschlussseite. Belegbar sind diese nur
über Server-Logs (nur wenige Stunden Rückblick) oder den Mailserver. Eine im
Browser gemerkte Unterschrift wird nur dort vorbelegt, wo zu dieser E-Mail
schon unterschrieben wurde (verschlüsseltes Cookie `signature_uuids`).
Betrieb 2026-10-08: `SendFormCompletedWebhookRequestJob` lief im Abstand
128/256 Minuten erneut, d. h. ein `form.completed`-Webhook scheitert seit
dem 07.10. gegen 17 Uhr. Ziel-URL und Statuscodes stehen unter Einstellungen >
Webhooks. Beleg: Container-Logs, Code `send_form_completed_webhook_request_job.rb`.

## Offene Nachweise

Rails-Integration, visuelle Empfängeroberflächen und Wiederherstellung bei einem
Upstreamwechsel bleiben konkrete Betriebsprüfungen mit Testdaten. Ein grüner
Offlinecheck schließt diese Punkte nicht ab.
