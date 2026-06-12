# OKorn DocuSeal Branding-Overlay

OKorn-gebrandetes Custom-Docker-Image basierend auf [DocuSeal OSS](https://github.com/docusealco/docuseal).

**Production-Deployment:** `https://sign.okorn.biz` (Coolify-Service `yw44sccgksosw8oksgw4ws8k` auf `clserve1`).

## Was dieses Repo macht

DocuSeal OSS wird unveraendert als Basis-Image (`docuseal/docuseal:latest`) verwendet. Dieses Overlay legt drei Klassen von Override-Dateien drueber:

1. **Static Assets** (`overrides/public/`) — OKorn-Logo (PNG), Favicons, Apple-Touch-Icon.
2. **View-Partials** (`overrides/app/views/`) — vier ERB-Files, die sichtbare Headlines „DocuSeal" durch „OKorn Immobilien" ersetzen:
   - `shared/_logo.html.erb` (Inline-SVG -> `<img>`-Tag)
   - `start_form/_docuseal_logo.html.erb`
   - `submit_form/_docuseal_logo.html.erb`
   - `templates_share_link_qr/_logo.html.erb`
3. **i18n-Override** (`overrides/config/locales/zz_okorn_overrides.de.yml`) — aendert deutschen `powered_by`-Wert von „Bereitgestellt von" zu „Erstellt mit".
4. **Neutrale Startseite** (`overrides/app/views/pages/landing.html.erb`, Full-File-Override Basis 3.0.3) — ersetzt das DocuSeal-Produkt-Marketing durch „Signatur-Plattform / OKorn Immobilien" mit kurzem Empfaenger-Hinweis; AGPL-Attribution am Seitenende bleibt erhalten. Dazu `shared/_title.html.erb`: Navbar-Schriftzug „DocuSeal" → „OKorn Immobilien".
5. **Builder-Logo-CSS-Swap** (`overrides/app/views/templates/edit.html.erb`, `overrides/app/views/templates_preview/show.html.erb`) — Full-File-Overrides der Builder-Mount-Views: Das Editor-Logo kommt aus dem JS-Bundle (`template_builder/logo.vue`) und ist nicht per Partial overridebar; ein CSS-Block blendet das SVG aus und zeigt `/logo.png` als Hintergrund des `<a href="/">`.
6. **Button-Loesung § 312j Abs. 3 BGB** (`overrides/app/views/submit_form/show.html.erb`) — Full-File-Override der Hosted-Form-View (Basis: Upstream-Tag, siehe Kommentar-Block am Dateiende). Ein MutationObserver-Snippet schreibt den finalen Abschluss-Button (`#submit_form_button`) und die E-Signatur-Einwilligungszeile um. **Drei Trigger** (gelten pro Submitter/Rolle):
   1. **Marker im Template** (direkt im DocuSeal-Editor nutzbar, kein Chatbot noetig): `##button: Eigener Text##` oder `##button->Eigener Text##` in Feldname, Feldtitel oder Feldbeschreibung eines Feldes der jeweiligen Rolle → Button-Text = exakt dieser Text. Sichtbare Marker werden aus der Anzeige entfernt.
   2. **Keyword**: Ein Feldname/-titel der Rolle enthaelt „zahlungspflichtig" → Standard-Text „Zahlungspflichtig / provisionspflichtig abschließen".
   3. **API-Metadata** `payment_notice` am Submitter (setzt ok_manage bei `requiresPaymentNotice=true`, Feature 023) → Standard-Text.

   Vorgaenge ohne Trigger bleiben unveraendert. Hintergrund: Embedded Components sind bei selfhosted DocuSeal Pro-only; dieses Override patcht stattdessen die OSS-Hosted-Form. Details: ok_manage-Spec `023-docuseal-signing-slice`.

**Explizit NICHT geaendert** (Lizenz-Compliance, AGPLv3 + Section 7(b) Attribution):

- `app/views/shared/_powered_by.html.erb` und alle `_attribution`-Partials bleiben unangetastet.
- `lib/docuseal.rb` (`PRODUCT_NAME` bleibt „DocuSeal") wird nicht ueberschrieben.
- Email-Layout (`app/views/layouts/mailer.html.erb`) und Email-Attribution bleiben original.

Resultat: auf jeder Empfaenger-Surface (Start-Form, Submit-Form, Completed, Success) ist der Footer „Erstellt mit DocuSeal" sichtbar — DocuSeal bleibt klar attributiert.

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
   - `app/views/submit_form/show.html.erb` — **Full-File-Override!** Bei jedem Upstream-Bump: Datei vom neuen Tag frisch ziehen (`gh api "repos/docusealco/docuseal/contents/app/views/submit_form/show.html.erb?ref=<TAG>" --jq .content | base64 -d`) und den `OKorn-Override`-Block vom Dateiende wieder anhaengen.
   - `app/javascript/submission_form/form.vue` — existiert `#submit_form_button` noch?
   - `app/javascript/submission_form/i18n.js` — Keys `sign_and_complete` / `complete` unveraendert?
   - `app/javascript/submission_form/signature_step.vue` — Disclosure-Zeile enthaelt weiterhin den `esign-disclosure`-Link?
   - `app/views/pages/landing.html.erb` — **Full-File-Override!** Bei Upstream-Bumps pruefen, ob `shared/attribution` und `shared/logo` noch existieren.
   - `app/views/shared/_title.html.erb` — Mini-Override (Logo + Schriftzug).
   - `app/views/templates/edit.html.erb` + `app/views/templates_preview/show.html.erb` — **Full-File-Overrides!** Bei jedem Upstream-Bump frisch vom neuen Tag ziehen und den `OKorn-Override`-Style-Block wieder anhaengen; `template_builder/builder.vue` muss weiterhin `<a href="/"><Logo/></a>` rendern.
   - Favicons/Logo: alle Dateien in `overrides/public/` werden aus `branding-source/okorn-logo-element.jpg` generiert (transparent via ImageMagick `-fuzz 12% -transparent white -trim`); `favicon.svg` traegt das PNG als eingebettete data-URI (externe Referenzen sind in SVG-Favicons blockiert).
3. Falls Pfade umbenannt: Override-File-Namen im `overrides/`-Tree mitziehen.
4. **PR mergen** -> GH-Action baut neues Image -> Renovate-Branch geschlossen.
5. **Coolify-Cutover** (siehe unten).

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
- [ ] Coolify-UI: `image:` zurueck auf `docuseal/docuseal:latest`
- [ ] Redeploy
      (DB- und Data-Volume sind unberuehrt, Rollback ist sofort wirksam)
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
