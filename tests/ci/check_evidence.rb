# frozen_string_literal: true

# Prueft im CI-Container, ob das Beweisprotokoll die erwarteten Eintraege
# enthaelt und die Hash-Kette intakt ist. Erwartet ENV DESKTOP_SLUG,
# LANDSCAPE_SLUG, PLAIN_SLUG und optional E2E=1 (Browser-Klicks gelaufen).

abort 'check_evidence.rb laeuft nur mit OKORN_CI=1' unless ENV['OKORN_CI'] == '1'

failures = []
entries = OkornEvidence.entries.to_a
label = OkornButtonLabel::DEFAULT_LABEL

find = lambda do |event, slug, &block|
  entries.select { |e| e['event'] == event && e.to_json.include?(slug) && (block.nil? || block.call(e)) }
end

check = ->(ok, message) { failures << message unless ok }

desktop = ENV.fetch('DESKTOP_SLUG')
landscape = ENV.fetch('LANDSCAPE_SLUG')
plain = ENV.fetch('PLAIN_SLUG')

served = find.call('http.signing_page', desktop) { |e| e.dig('data', 'button', 'label') == label }
check.call(served.any?, 'http.signing_page mit Beschriftung fuer DESKTOP fehlt')
check.call(served.all? { |e| e.dig('data', 'button', 'trigger') == 'keyword' }, 'Ausloeser sollte keyword sein')

plain_served = find.call('http.signing_page', plain)
check.call(plain_served.any?, 'http.signing_page fuer PLAIN fehlt')
check.call(plain_served.all? { |e| e.dig('data', 'button', 'label').nil? }, 'PLAIN darf keine Beschriftung haben')

beacon = find.call('button_click', desktop) { |e| e.dig('data', 'client', 'is_trusted') == false }
check.call(beacon.any? { |e| e.dig('data', 'check', 'text_matches_label') == true }, 'curl-Beacon fuer DESKTOP fehlt')

mail = entries.select { |e| e['event'] == 'mail' && e.dig('data', 'action') == 'invitation_email' }
check.call(mail.any?, 'mail-Eintrag fehlt')
check.call(mail.all? { |e| e.dig('data', 'delivery', 'method') == 'test' && e.dig('data', 'delivery', 'actually_sent') == false },
           'ohne SMTP muss actually_sent=false protokolliert sein')
check.call(mail.all? { |e| e.dig('data', 'raw', 'sha256').to_s.size == 64 }, 'Archivkopie (.eml) fehlt')

if ENV['E2E'] == '1'
  [desktop, landscape].each do |slug|
    clicks = find.call('button_click', slug) { |e| e.dig('data', 'client', 'is_trusted') == true }
    check.call(clicks.any? { |e| e.dig('data', 'check', 'text_matches_label') && e.dig('data', 'check', 'rendered_matches_label') },
               "echter Browser-Klick mit passender Beschriftung fehlt (#{slug})")
    check.call(clicks.all? { |e| e.dig('data', 'client', 'form_language') == 'de' }, "Formular nicht auf Deutsch (#{slug})")
    completed = find.call('http.form_completed', slug) { |e| e.dig('data', 'button', 'label') == label }
    check.call(completed.any?, "http.form_completed mit Beschriftung fehlt (#{slug})")
  end
end

report = OkornEvidence.verify
check.call(report[:ok], "Hash-Kette defekt: #{report[:errors].first(3).inspect}")

puts JSON.pretty_generate('entries' => entries.size, 'verify' => report.except(:errors), 'events' => entries.map { |e| e['event'] }.tally)
if failures.any?
  warn "FEHLER:\n- #{failures.join("\n- ")}"
  exit 1
end
puts 'Beweisprotokoll OK'
