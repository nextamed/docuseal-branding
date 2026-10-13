# frozen_string_literal: true

# Prueft im CI-Container, ob das Beweisprotokoll die erwarteten Eintraege
# enthaelt und die Hash-Kette intakt ist. Erwartet ENV DESKTOP_SLUG, DESKTOP_SUBMISSION_ID,
# LANDSCAPE_SLUG, PLAIN_SLUG und optional E2E=1 (Browser-Klicks gelaufen).

abort 'check_evidence.rb laeuft nur mit OKORN_CI=1' unless ENV['OKORN_CI'] == '1'

failures = []
entries = OkornEvidence.entries.to_a
label = OkornButtonLabel::DEFAULT_LABEL
check = ->(ok, message) { failures << message unless ok }

slugs = { desktop: ENV.fetch('DESKTOP_SLUG'), landscape: ENV.fetch('LANDSCAPE_SLUG'), plain: ENV.fetch('PLAIN_SLUG') }
digest = slugs.transform_values { |slug| OkornEvidence.slug_digest(slug) }

of = lambda do |event, who, &block|
  entries.select do |e|
    e['event'] == event && e.dig('data', 'submitter', 'slug_sha256') == digest.fetch(who) && (block.nil? || block.call(e))
  end
end

raw_text = Dir.glob(File.join(OkornEvidence.dir, 'evidence-*.jsonl')).map { |f| File.read(f) }.join
slugs.each { |name, slug| check.call(!raw_text.include?(slug), "Slug #{name} steht im Klartext im Protokoll") }

served = of.call('http.signing_page', :desktop)
check.call(served.any? { |e| e.dig('data', 'button', 'label') == label && e.dig('data', 'button', 'trigger') == 'keyword' },
           'http.signing_page mit Beschriftung (keyword) fuer DESKTOP fehlt')
check.call(served.all? { |e| e.dig('data', 'button', 'label_has_payment_wording') == true }, 'label_has_payment_wording fehlt')
check.call(served.all? { |e| e.dig('data', 'render_id').to_s.size == 36 }, 'render_id fehlt')
check.call(served.none? { |e| e.dig('data', 'path').to_s.include?(slugs[:desktop]) }, 'Pfad nicht maskiert')

plain_served = of.call('http.signing_page', :plain)
check.call(plain_served.any?, 'http.signing_page fuer PLAIN fehlt')
check.call(plain_served.all? { |e| e.dig('data', 'button', 'label').nil? }, 'PLAIN darf keine Beschriftung haben')

check.call(entries.none? { |e| e['event'] == 'button_click' && e.dig('data', 'render_id').nil? },
           'Klick-Nachweis ohne gueltiges Token wurde protokolliert')

attempts = entries.select { |e| e['event'] == 'mail_attempt' && e.dig('data', 'action') == 'invitation_email' }
mails = entries.select { |e| e['event'] == 'mail' && e.dig('data', 'action') == 'invitation_email' }
check.call(attempts.any?, 'mail_attempt fehlt')
check.call(mails.any?, 'mail-Eintrag fehlt')
check.call(mails.all? { |e| e.dig('data', 'delivery', 'method') == 'test' && e.dig('data', 'delivery', 'accepted_by_smtp_relay') == false },
           'ohne SMTP muss method=test und accepted_by_smtp_relay=false protokolliert sein')
check.call(mails.all? { |e| attempts.map { |a| a['seq'] }.include?(e.dig('data', 'attempt_seq')) }, 'mail ohne zugehoerigen mail_attempt')
check.call(mails.all? { |e| e.dig('data', 'raw', 'sha256').to_s.size == 64 }, 'Archivkopie (.eml) fehlt')

if ENV['E2E'] == '1'
  %i[desktop landscape].each do |who|
    render_ids = of.call('http.signing_page', who).map { |e| e.dig('data', 'render_id') }
    clicks = of.call('button_click', who) { |e| e.dig('data', 'client', 'is_trusted') == true }
    check.call(clicks.any? { |e| e.dig('data', 'check', 'text_matches_label') && e.dig('data', 'check', 'rendered_matches_label') },
               "echter Browser-Klick mit passender Beschriftung fehlt (#{who})")
    check.call(clicks.all? { |e| render_ids.include?(e.dig('data', 'render_id')) }, "Klick nicht an ausgelieferte Seite gebunden (#{who})")
    check.call(clicks.all? { |e| e.dig('data', 'client', 'form_language') == 'de' }, "Formular nicht auf Deutsch (#{who})")
    completed = of.call('http.form_completed', who) { |e| e.dig('data', 'button', 'label') == label }
    check.call(completed.any?, "http.form_completed mit Beschriftung fehlt (#{who})")
  end
end

export = OkornEvidence.export(submission_id: ENV.fetch('DESKTOP_SUBMISSION_ID').to_i)
check.call(export['matching'].positive?, 'Export findet den Vorgang nicht')
check.call(export['chain'].size >= entries.size, 'Export muss die ganze (teils geschwaerzte) Kette enthalten')

report = OkornEvidence.verify
check.call(report[:ok], "Hash-Kette defekt: #{report[:errors].first(3).inspect}")

puts JSON.pretty_generate('entries' => entries.size, 'verify' => report.except(:errors),
                          'events' => entries.map { |e| e['event'] }.tally, 'export_matching' => export['matching'])
if failures.any?
  warn "FEHLER:\n- #{failures.join("\n- ")}"
  exit 1
end
puts 'Beweisprotokoll OK'
