# OKorn DocuSeal Branding-Overlay

OKorn-gebrandetes Custom-Docker-Image basierend auf [DocuSeal OSS](https://github.com/docusealco/docuseal).

**Production-Deployment:** `https://sign.okorn.biz` (Coolify-Service `yw44sccgksosw8oksgw4ws8k` auf `clserve1`).

## Was dieses Repo macht

DocuSeal OSS wird unveraendert als Basis-Image verwendet. Die Version ist im Dockerfile gepinnt (`ARG DOCUSEAL_VERSION`, aktuell **3.3.1**), damit reproduzierbar ist, gegen welchen Upstream-Stand die Full-File-Overrides gebaut wurden; Renovate hebt den Pin bei neuen Releases an. Dieses Overlay legt drei Klassen von Override-Dateien drueber:

1. **Static Assets** (`overrides/public/`) — OKorn-Logo (PNG), Favicons, Apple-Touch-Icon.
2. **View-Partials** (`overrides/app/views/`) — vier ERB-Files, die sichtbare Headlines „DocuSeal" durch „OKorn Immobilien" ersetzen:
   - `shared/_logo.html.erb` (Inline-SVG -> `<img>`-Tag)
   - `start_form/_docuseal_logo.html.erb`
   - `submit_form/_docuseal_logo.html.erb`
   - `templates_share_link_qr/_logo.html.erb`
3. **i18n-Override** (`overrides/config/locales/zz_okorn_overrides.de.yml`) — aendert deutschen `powered_by`-Wert von „Bereitgestellt von" zu „Erstellt mit".
4. **Neutrale Titel/Metas** (`overrides/app/views/layouts/_head_tags.html.erb`, `overrides/app/views/shared/_meta.html.erb`) — Browser-Tab-Titel „OKorn Immobilien — Signatur-Plattform" statt DocuSeal-Produktname; OpenGraph/Description neutralisiert, Twitter-Handles entfernt, `og:site_name` = OKorn Immobilien. Favicon-Links unveraendert. Die Tab-Titel der Empfaengerseiten (Start-Form, Submit-Form, E-Mail-2FA) setzt seit Upstream 3.3.1 das Mini-Partial `shared/_html_title.html.erb` („… | OKorn Immobilien").
5. **Neutrale Startseite** (`overrides/app/views/pages/landing.html.erb`, Full-File-Override, Basis 3.3.1 — upstream seit 3.0.3 unveraendert) — ersetzt das DocuSeal-Produkt-Marketing durch „Signatur-Plattform / OKorn Immobilien" mit kurzem Empfaenger-Hinweis; AGPL-Attribution am Seitenende bleibt erhalten. Dazu `shared/_title.html.erb`: Navbar-Schriftzug „DocuSeal" → „OKorn Immobilien".
6. **Builder-Logo-CSS-Swap** (`overrides/app/views/templates/edit.html.erb`, `overrides/app/views/templates_preview/show.html.erb`) — Full-File-Overrides der Builder-Mount-Views: Das Editor-Logo kommt aus dem JS-Bundle (`template_builder/logo.vue`) und ist nicht per Partial overridebar; ein CSS-Block blendet das SVG aus und zeigt `/logo.png` als Hintergrund des `<a href="/">`.
7. **Button-Loesung § 312j Abs. 3 BGB** (`overrides/app/views/submit_form/show.html.erb`, `overrides/config/okorn/button_label.rb`) — Full-File-Override der Hosted-Form-View (Basis: Upstream-Tag 3.3.1). Die Beschriftung bestimmt `OkornButtonLabel` als einzige Quelle fuer Anzeige und Beweisprotokoll. **Drei Ausloeser** (gelten pro Submitter/Rolle):
   1. **Marker im Template**: `##button: Eigener Text##` oder `##button->Eigener Text##` in Feldname, Feldtitel oder Feldbeschreibung eines Feldes der Rolle → Button-Text = exakt dieser Text. Sichtbare Marker werden aus der Anzeige entfernt.
   2. **API-Metadata** `payment_notice` am Submitter (setzt ok_manage bei `requiresPaymentNotice=true`, Feature 023) → Standard-Text „Zahlungspflichtig / provisionspflichtig abschließen".
   3. **Keyword**: Ein Feldname/-titel der Rolle enthaelt „zahlungspflichtig" → Standard-Text.

   Bei aktivem Ausloeser (seit 2026-10-13): Formular immer auf Deutsch (unabhaengig von der Browsersprache), Kopfzeilen-Schaltflaeche „Abschließen" ausgeblendet, Umbeschriftung aller Abschluss-Texte („Unterzeichnen und abschließen", „Abschließen", „Einreichen" im Handy-Querformat, Einladungsformular, Hinweistext „klicken Sie auf …") ueber die bestehenden Textknoten, und ein Klick-Nachweis (siehe Beweisprotokoll). Im Handy-Querformat steht die Beschriftung bewusst auch auf Zwischenschritten. Sichtbar ist der Text in Grossbuchstaben (daisyUI `--btn-text-case`). Vorgaenge ohne Ausloeser bleiben unveraendert.

8. **Beweisprotokoll** (`overrides/config/okorn/evidence*.rb`, `overrides/config/initializers/zz_okorn_evidence.rb`, `overrides/app/controllers/okorn_button_evidence_controller.rb`) — reiner Beobachter, siehe Abschnitt „Beweisprotokoll".

**Explizit NICHT geaendert** (Lizenz-Compliance, AGPLv3 + Section 7(b) Attribution):

- `app/views/shared/_powered_by.html.erb` und alle `_attribution`-Partials bleiben unangetastet.
- `lib/docuseal.rb` (`PRODUCT_NAME` bleibt „DocuSeal") wird nicht ueberschrieben.
- Email-Layout (`app/views/layouts/mailer.html.erb`) und Email-Attribution bleiben original.

Resultat: auf jeder Empfaenger-Surface (Start-Form, Submit-Form, Completed, Success) ist der Footer „Erstellt mit DocuSeal" sichtbar — DocuSeal bleibt klar attributiert.

## Beweisprotokoll

Seit 2026-10-13 schreibt das Overlay ein manipulationsevidentes Protokoll mit (Format v2). Es beobachtet nur (ActiveSupport-Notifications, Mail-Interceptor/-Observer) und greift nie in Signatur oder Mailversand ein; Fehler werden geloggt und verschluckt. Abschalten: `OKORN_EVIDENCE=off`.

| Ereignis | Inhalt |
|---|---|
| `http.signing_page` | Signaturformular ausgeliefert: Unterzeichner, IP, User-Agent, `render_id` dieser Auslieferung, **ausgelieferte Button-Beschriftung und Ausloeser**, erzwungene Sprache, Kopfzeilen-Button ausgeblendet. Andere Seiten unter `/s/…` (abgeschlossen, abgelehnt, abgelaufen) laufen als `http.signing_page_other` |
| `http.step_saved`, `http.form_completed`, `http.form_complete_rejected` | Formularschritt bzw. Abschluss (mit Beschriftung, IP, User-Agent) bzw. vom Server abgelehnter Abschluss |
| `button_click` | Klick-Nachweis aus dem Browser (Maus oder Enter): Text und sichtbarer Text der ausgeloesten Schaltflaeche, `is_trusted`, sichtbar/verdeckt, Groesse, Stil, Formularsprache; Vergleich mit der serverseitig ausgelieferten Beschriftung (`check.text_matches_label`, `check.rendered_matches_label`). Angenommen nur mit signiertem Token aus einer ausgelieferten Seite (`render_id`, 12 h gueltig, bis 15 min nach Abschluss), gedrosselt pro Auslieferung und IP |
| `http.completed_page`, `http.download_links`, `http.file_download`, `http.preview_*` | Abschlussseite, Download-Links, tatsaechlicher Datei-Abruf (Dateiname, SHA-256 hex und base64url wie im DocuSeal-Pruefprotokoll, Zuordnung zum Vorgang), Link aus der Kopie-Mail |
| `http.resubmit`, `http.copy_email_requested`, `http.decline`, `http.form_viewed`, `http.email_click`, `http.admin_*` | Erneut einreichen, „Kopie per E-Mail senden", Ablehnen, Formular geoeffnet, Link in Einladung geklickt, Admin-Aenderungen an Vorgaengen/Unterzeichnern (mit Benutzer-ID) |
| `mail_attempt`, `mail` | `mail_attempt` vor der Zustellung, `mail` nach erfolgreicher Uebergabe (`attempt_seq` verbindet beide; ein Versuch ohne `mail` ist gescheitert). Empfaenger, Betreff, Message-ID, Zustellweg (`delivery.method`, `delivery.accepted_by_smtp_relay`; `test` = **nicht versendet**), Anhaenge mit SHA-256; Einladungen und Dokumentkopien zusaetzlich als `.eml`-Archivkopie (keine Einmalcodes) |
| `recovered_partial_write`, `evidence_shipped`, `evidence_changed_after_ship`, `redacted_before` | Betrieb des Protokolls selbst |

**Ablage:** `/data/docuseal/okorn-evidence/` auf dem persistenten Volume (`evidence-YYYY-MM-DD.jsonl`, Tage in UTC, `chain_head.json` nur als Zwischenspeicher, `mail/…/*.eml` schreibgeschuetzt, `quarantine/` fuer abgebrochene Zeilen). Jeder Eintrag enthaelt Laufnummer, Zeitstempel (unter Dateisperre gesetzt), Ereignis, den SHA-256 seines Vorgaengers und einen gesalzenen Commitment-Hash seiner Daten. Aenderung, Einfuegen oder Loeschen bricht die Kette; Daten eines Eintrags lassen sich dagegen schwaerzen (Datenschutz), ohne die Kette zu brechen. Signatur-Slugs stehen nie im Klartext im Protokoll (`slug_sha256`, Pfade maskiert). Gegen das Neuschreiben der ganzen Kette hilft nur die Auslagerung in schreibgeschuetzten Speicher (unten).

**Pruefen und exportieren** (im DocuSeal-Container, z. B. ueber das Coolify-Terminal):

```bash
/app/bin/bundle exec rails runner 'puts JSON.pretty_generate(OkornEvidence.verify.except(:errors))'
/app/bin/bundle exec rails runner 'File.write("/data/docuseal/okorn-export-180.json", JSON.pretty_generate(OkornEvidence.export(submission_id: 180)))'
```

Der Export enthaelt die ganze Kette; Eintraege anderer Vorgaenge sind darin geschwaerzt (nur Hash-Felder), damit Dritte die Verkettung bis zu einem Anker nachrechnen koennen, ohne fremde Daten zu sehen. Nach Ablauf der Aufbewahrung: `OkornEvidence.redact_before!(Time.utc(2033, 1, 1))` schwaerzt aeltere Eintraege und loescht deren `.eml`.

**Auslagerung (WORM):** `OkornEvidence::Shipper.run` laedt abgeschlossene Tagesdateien (nicht den laufenden Tag) und Mail-Archive in einen S3-Bucket mit Object Lock und legt bei jedem Lauf unter `anchors/` einen Anker mit Kettenkopf und Pruefergebnis ab. Daten: `OKORN_EVIDENCE_LOCK_MODE` (Standard GOVERNANCE, damit Loeschpflichten erfuellbar bleiben); Anker ohne Personenbezug: `OKORN_EVIDENCE_ANCHOR_LOCK_MODE` (Standard COMPLIANCE, auch der Kontoinhaber kann sie vor Fristablauf nicht loeschen); Frist `OKORN_EVIDENCE_LOCK_DAYS` (Standard 2192 = 6 Jahre). Bereits ausgelagerte Dateien werden nie ueberschrieben: aendert sich eine, kommt sie unter neuem Schluessel dazu und `evidence_changed_after_ship` wird protokolliert. Einrichtung: Bucket mit Object Lock anlegen, Zugang (nur PutObject und PutObjectRetention) als Coolify-Umgebungsvariablen mit Praefix `OKORN_EVIDENCE_S3_` am DocuSeal-Service, taeglicher Coolify Scheduled Task `/app/bin/bundle exec rails runner 'OkornEvidence::Shipper.run'`. Ohne Konfiguration passiert nichts.

**Grenzen:** Das Protokoll belegt die Uebergabe einer Mail an den Mailserver, nicht den Zugang beim Empfaenger (dafuer Mailserver-Protokoll). Der Klick-Nachweis stammt aus dem Browser des Unterzeichners und ist Selbstauskunft dieses Browsers; das Token bindet ihn an eine tatsaechlich ausgelieferte Seite, macht ihn aber nicht unfaelschbar. Zusammen mit der serverseitig protokollierten Beschriftung, dem Quelltext dieses Repos zum ausgerollten Commit (`OKORN_OVERLAY_REVISION`) und den CI-Referenz-Screenshots ergibt sich das Gesamtbild. Abschluesse ohne Klick und ohne Enter haben keinen Klick-Nachweis, aber einen `http.form_completed`-Eintrag. Protokolliert wird erst ab dem Deploy dieses Stands, aeltere Vorgaenge sind nicht erfasst. Rechtliche Bewertung durch Anwalt; Datenschutzhinweis (IP, User-Agent, Klick-Nachweis, Mail-Archiv, Aufbewahrung, berechtigtes Interesse an Beweissicherung) ergaenzen.

**CI-Referenz:** Jeder Build startet das Image in einem Wegwerf-Container, legt synthetische Testdaten an und klickt mit Chromium (Browsersprache fr) die Unterschrift durch, am Desktop und im Handy-Querformat. Geprueft werden unter anderem: Beschriftung im DOM und sichtbar, Kopfzeilen-Button verborgen, Klick-Nachweis an die ausgelieferte Seite gebunden, gefaelschter Klick-Nachweis ohne Token nicht protokolliert, Mail mit `mail_attempt`, kein Slug im Klartext, Kette intakt. Screenshots der echten Schaltflaeche und das Beweisprotokoll des Laufs liegen als Artefakt `okorn-smoke-<commit>` 90 Tage an der Action; fuer jede ausgerollte Version herunterladen und archivieren.

## Build

GitHub Actions baut bei jedem Push auf `main` automatisch ein neues Image und pusht nach `ghcr.io/nextamed/docuseal-branding:latest`. Renovate verfolgt Upstream-DocuSeal-Releases und legt PRs bei neuen Versionen an (jeden Montag vor 5:00 Uhr).

Lokaler Build (zum Test):

```bash
docker build -t okorn-docuseal:test .
# Anschliessend gegen vorhandenen Postgres testen oder docker-compose nutzen.
```

## Erst-Setup: GHCR-Image auf public stellen

Beim ersten Push erstellt GHCR das Package als **private**. Damit Coolify ohne Pull-Secret das Image ziehen kann, muss es auf **public** umgestellt werden:

1. https://github.com/users/nextamed/packages/container/docuseal-branding/settings
2. Bereich „Danger Zone" -> „Change package visibility" -> Public

## Update-Prozess (neue DocuSeal-Version)

1. **Renovate** legt automatisch einen PR an, wenn DocuSeal eine neue Version released.
2. **Vor dem Merge pruefen**: Haben sich diese Pfade upstream geaendert?
   - `app/views/shared/_logo.html.erb`
   - `app/views/start_form/_docuseal_logo.html.erb`
   - `app/views/submit_form/_docuseal_logo.html.erb`
   - `app/views/templates_share_link_qr/_logo.html.erb`
   - `config/locales/i18n.yml` (Key `powered_by` in `de:`-Section)
   - `app/views/submit_form/show.html.erb` — **Full-File-Override!** Bei jedem Upstream-Bump: Datei vom neuen Tag frisch ziehen (`gh api "repos/docusealco/docuseal/contents/app/views/submit_form/show.html.erb?ref=<TAG>" --jq .content | base64 -d`) und den `OKorn-Override`-Block vom Dateiende wieder anhaengen, dazu die zwei OKorn-Zeilen vor `render 'submit_form/submission_form'` (`okorn_button = …`, `I18n.with_locale(…)`).
   - Beweisprotokoll: Controller-Namen und Routen-Parameter in `config/okorn/evidence_rails.rb` (`SIGNER_CONTROLLERS`, `describe`) gegen `config/routes.rb` des neuen Tags pruefen, ebenso `SubmitterMailer`-Aktionen (`RAW_MAIL_ACTIONS`). Der CI-Smoke-/Browser-Test muss gruen sein.
   - `app/javascript/submission_form/form.vue` — existiert `#submit_form_button` noch?
   - `app/javascript/submission_form/i18n.js` — Keys `sign_and_complete` / `complete` / `submit` (de) unveraendert?
   - `app/javascript/submission_form/signature_step.vue` — Disclosure-Zeile enthaelt weiterhin den `esign-disclosure`-Link?
   - `app/views/pages/landing.html.erb` — **Full-File-Override!** Bei Upstream-Bumps pruefen, ob `shared/logo` noch existiert. Rendert bewusst KEINE Attribution (kein Pflicht-Surface; die vier Empfaenger-Surfaces behalten ihre).
   - `app/views/layouts/_head_tags.html.erb` + `app/views/shared/_meta.html.erb` — kleine Overrides; bei Upstream-Bumps gegen neue Meta-/Title-Logik diffen.
   - `app/views/shared/_html_title.html.erb` — Mini-Override (Tab-Titel der Empfaengerseiten); pruefen, ob Start-/Submit-Form den Partial weiterhin rendern.
   - `app/views/shared/_title.html.erb` — Mini-Override (Logo + Schriftzug).
   - `app/views/templates/edit.html.erb` + `app/views/templates_preview/show.html.erb` — **Full-File-Overrides!** Bei jedem Upstream-Bump frisch vom neuen Tag ziehen und den `OKorn-Override`-Style-Block wieder anhaengen; `template_builder/builder.vue` muss weiterhin `<a href="/"><Logo/></a>` rendern.
   - Favicons/Logo: alle Dateien in `overrides/public/` werden aus `branding-source/okorn-logo-element.jpg` generiert (transparent via ImageMagick `-fuzz 12% -transparent white -trim`); `favicon.svg` traegt das PNG als eingebettete data-URI (externe Referenzen sind in SVG-Favicons blockiert).
3. Falls Pfade umbenannt: Override-File-Namen im `overrides/`-Tree mitziehen.
4. **PR mergen** -> GH-Action baut neues Image -> Renovate-Branch geschlossen.
5. **Coolify-Cutover** (siehe unten).

### Upstream-Historie

| Datum | Upstream | Angepasste Overrides |
|---|---|---|
| 2025-05 | 3.0.3 | Erst-Setup |
| 2026-09-08 | **3.2.4** | `submit_form/show.html.erb` (Viewer-Rolle, `template&.name`, `service_url_time`, `with_signature_id_completed_at`), `templates/edit.html.erb` (`data-date-formats`) — alle uebrigen Override-Pfade upstream unveraendert; JS-Hooks (`#submit_form_button`, `sign_and_complete`/`complete`, `esign-disclosure`) und `powered_by` (de) verifiziert |
| 2026-10-07 | **3.3.1** | `submit_form/show.html.erb` (`shared/html_title`, Native-App-Zweige, neue Formular-Locals `prefill_signature`/`prefill_initials`/`current_user_data` — alter Override haette die Signaturseite gebrochen), `templates/edit.html.erb` + `templates_preview/show.html.erb` (`native_title`, `data-native-platform`), `layouts/_head_tags.html.erb` (Native-App-Titel/-Styles); neu `shared/_html_title.html.erb`. Logo-Partials, Landing, Meta, `_title` upstream unveraendert; JS-Hooks (`#submit_form_button`, `sign_and_complete`/`complete`, `esign-disclosure`, Builder-`<a href="/"><Logo/></a>`) und `powered_by` (de) verifiziert |

## Coolify-Cutover-Checkliste

```
Vor Cutover:
- [ ] Postgres-Volume-Snapshot erstellt
      (Coolify-UI: Database -> Backup,
       oder: docker exec postgresql-yw44sccgksosw8oksgw4ws8k pg_dump -U $POSTGRES_USER $POSTGRES_DB > backup.sql)
- [ ] DocuSeal-Data-Volume-Snapshot erstellt
      (Server-Shell: tar -czf docuseal-data-$(date +%Y%m%d).tgz /var/lib/docker/volumes/yw44sccgksosw8oksgw4ws8k_docuseal-data/)
- [ ] Staging-Smoke-Test gruen (alle 4 Empfaenger-Surfaces visuell ok)
- [ ] GHCR-Image-Tag dokumentiert (`latest` + commit-sha)

Cutover (Coolify-UI):
- [ ] Service `yw44sccgksosw8oksgw4ws8k` -> „Service Stack"
- [ ] Docker-Compose: `image: 'docuseal/docuseal:latest'`
      ersetzen durch `image: 'ghcr.io/nextamed/docuseal-branding:latest'`
- [ ] Speichern
- [ ] Service -> „Move to Project" -> OKorn (uuid `ogw4k4kgoscskw4c0w0wgcw4`)
- [ ] „Deploy" druecken, Healthcheck abwarten (~30s)

Nach Cutover:
- [ ] Browser-Test der 4 Surfaces auf https://sign.okorn.biz
  - Start-Form (`/start/<slug>`): OKorn-Logo + Headline + „Erstellt mit DocuSeal"-Footer
  - Submit-Form (`/d/<slug>`): OKorn-Logo + Headline + Footer
  - Submit-Form completed/success: Footer
  - QR-Share-Page (Backoffice): OKorn-Logo + Headline
- [ ] 1 bestehendes Template oeffnen + Submission-Vorschau testen
- [ ] Test-Submission an eigene Email triggern
      (Email kommt zunaechst in englisch mit DocuSeal-Logo — ok fuer Phase 1, gehoert zu Phase 2/3)

Rollback (falls noetig):
- [ ] Vorherigen, vor dem Update dokumentierten Image-Digest wieder einsetzen
- [ ] Vorher pruefen, ob die neue Upstream-Version Datenmigrationen ausgefuehrt hat;
      Image-Ruecknahme allein garantiert keine Datenkompatibilitaet
- [ ] Autorisierten Rueckweg ausfuehren, Gesundheits- und betroffene Funktionstests wiederholen
```

## Phase-Status

Dieses Repo realisiert **Phase 1** der OKorn-Signing-Plattform (UI-Branding-Overlay). Phase 2 (n8n-Reminders + SMS) und Phase 3 (Embedded Signing in ok_manage + Notion-Lifecycle) sind in `ok_manage/Ideen/SPEC_DOCUSEAL_OKORN_PHASE_1.md` umrissen.

Bewusst zurueckgestellte Folgearbeiten:

- Email-Templates auf Deutsch + OKorn-Tone (Phase 2/3)
- Wasabi-Storage-Migration (eigener Mini-Schritt)
- DSGVO-Sweep (Cookie-Banner, Datenschutzerklaerung, AVV-Verzeichnis)
- SVG-Vektorisierung des Element-Logos (PNG reicht fuer Phase 1)
- Backoffice-Marketing-Texte (DocuSeal-Title-Tag in Tab-Bar; nicht Phase-1-blocker)

## Lizenz

Dieses Repo (Dockerfile, Overrides, Workflows) ist eigenstaendige Arbeit der OKorn Immobilien (Sebastian Goetz) und steht unter AGPL-3.0-or-later (passend zum DocuSeal-Upstream).

Das daraus gebaute Docker-Image enthaelt DocuSeal als Basis-Layer und unterliegt AGPLv3 + DocuSeal's [Section 7(b) Additional Terms](https://github.com/docusealco/docuseal/blob/master/LICENSE_ADDITIONAL_TERMS). Die DocuSeal-Attribution (`_powered_by` / `_attribution`-Partials) bleibt in der UI sichtbar; der Wortlaut wurde im deutschen Locale von „Bereitgestellt von" zu „Erstellt mit" angepasst (DocuSeal-Name + Link bleiben erhalten).
