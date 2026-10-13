#!/usr/bin/env bash
# Smoke- und E2E-Test des gebauten Overlay-Images in einem Wegwerf-Container
# (SQLite, synthetische Testdaten, keine Verbindung zu Produktion).
# Aufruf: tests/ci/smoke.sh <image> [--e2e]
set -euo pipefail

IMAGE="${1:?Image angeben}"
E2E="${2:-}"
NAME=okorn-smoke
ART="${ARTIFACTS:-ci-artifacts}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ART"

cleanup() {
  docker logs "$NAME" > "$ART/container.log" 2>&1 || true
  docker exec "$NAME" sh -c 'cat /data/docuseal/okorn-evidence/evidence-*.jsonl' > "$ART/evidence.jsonl" 2>/dev/null || true
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$NAME" -p 3000:3000 -e SECRET_KEY_BASE="$(openssl rand -hex 64)" -e HOST=localhost "$IMAGE" >/dev/null

echo "Warte auf DocuSeal ..."
for _ in $(seq 1 120); do
  if curl -fsS http://localhost:3000/up >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS http://localhost:3000/up >/dev/null || { echo "DocuSeal nicht erreichbar"; exit 1; }

runner() {
  docker exec -e OKORN_CI=1 -e DESKTOP_SLUG="${DESKTOP_SLUG:-}" -e LANDSCAPE_SLUG="${LANDSCAPE_SLUG:-}" \
    -e PLAIN_SLUG="${PLAIN_SLUG:-}" -e E2E="${E2E_DONE:-0}" -w /app "$NAME" /app/bin/bundle exec rails runner "$@"
}

echo "1) Initializer geladen"
runner 'abort "Hooks fehlen" unless OkornEvidence::RailsHooks.installed?; puts OkornEvidence.dir'

echo "2) Endpunkt existiert (ungueltiger Body -> 400, nicht Routing-404)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data 'kein json' http://localhost:3000/okorn/button_evidence)
[ "$code" = "400" ] || { echo "erwartet 400, bekam $code"; exit 1; }

echo "3) Testdaten anlegen"
docker exec "$NAME" mkdir -p /tmp/okorn-ci
docker cp "$HERE/seed.rb" "$NAME:/tmp/okorn-ci/seed.rb"
docker cp "$HERE/check_evidence.rb" "$NAME:/tmp/okorn-ci/check_evidence.rb"
SEED=$(runner /tmp/okorn-ci/seed.rb | tail -n 1)
echo "$SEED"
DESKTOP_SLUG=$(echo "$SEED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["desktop"])')
LANDSCAPE_SLUG=$(echo "$SEED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["landscape"])')
PLAIN_SLUG=$(echo "$SEED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plain"])')
export DESKTOP_SLUG LANDSCAPE_SLUG PLAIN_SLUG

echo "4) Signaturseite mit Browsersprache fr"
curl -fsS -H 'Accept-Language: fr-FR,fr;q=0.9' "http://localhost:3000/s/$DESKTOP_SLUG" > "$ART/desktop.html"
grep -q 'data-language="de"' "$ART/desktop.html" || { echo "Formular nicht auf Deutsch"; exit 1; }
grep -q 'id="okorn_payment_notice_button"' "$ART/desktop.html" || { echo "Buttonloesung fehlt"; exit 1; }
grep -q 'complete-button { display: none !important; }' "$ART/desktop.html" || { echo "Kopfzeilen-Button nicht ausgeblendet"; exit 1; }
curl -fsS -H 'Accept-Language: fr-FR,fr;q=0.9' "http://localhost:3000/s/$PLAIN_SLUG" > "$ART/plain.html"
if grep -q 'okorn_payment_notice_button' "$ART/plain.html"; then echo "Buttonloesung ohne Ausloeser aktiv"; exit 1; fi

echo "5) Klick-Nachweis per curl (is_trusted=false)"
body=$(printf '{"v":1,"slug":"%s","text":"%s","rendered":"%s","is_trusted":false,"kind":"drawer"}' \
  "$DESKTOP_SLUG" 'Zahlungspflichtig / provisionspflichtig abschließen' 'ZAHLUNGSPFLICHTIG / PROVISIONSPFLICHTIG ABSCHLIESSEN')
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data "$body" http://localhost:3000/okorn/button_evidence)
[ "$code" = "204" ] || { echo "Beacon erwartet 204, bekam $code"; exit 1; }

echo "6) Mail-Protokoll (ohne SMTP: Testzustellung)"
runner "SubmitterMailer.invitation_email(Submitter.find_by!(slug: ENV['DESKTOP_SLUG'])).deliver_now"

if [ "$E2E" = "--e2e" ]; then
  echo "7) Browser-Test"
  BASE_URL=http://localhost:3000 ARTIFACTS="$ART" node "$HERE/e2e.mjs"
  E2E_DONE=1
fi

echo "8) Beweisprotokoll pruefen"
runner /tmp/okorn-ci/check_evidence.rb
echo "Smoke-Test bestanden"
