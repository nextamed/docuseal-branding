# frozen_string_literal: true

# CI-Testdaten fuer den Smoke-/E2E-Test im Wegwerf-Container der CI.
# Synthetische Daten, keine echten Personen. Nie gegen Produktion ausfuehren.
# Aufruf: docker exec -e OKORN_CI=1 -w /app <container> /app/bin/bundle exec rails runner /tmp/okorn-ci/seed.rb

abort 'seed.rb laeuft nur mit OKORN_CI=1 (Wegwerf-Container der CI)' unless ENV['OKORN_CI'] == '1'

require 'hexapdf'
require 'json'

account = Account.create!(name: 'OKorn CI', locale: 'de-DE', timezone: 'Europe/Berlin')
user = User.create!(account:, first_name: 'CI', last_name: 'Admin', email: 'ci-admin@example.com',
                    password: SecureRandom.hex(16), role: User::ADMIN_ROLE)

def ci_pdf(title)
  doc = HexaPDF::Document.new
  canvas = doc.pages.add([0, 0, 595, 842]).canvas
  canvas.font('Helvetica', size: 16)
  canvas.text(title, at: [50, 780])
  canvas.font('Helvetica', size: 11)
  canvas.text('Synthetische Testdaten fuer den CI-Lauf des OKorn-Overlays.', at: [50, 750])
  io = StringIO.new
  doc.write(io)
  io.rewind
  io
end

def ci_template(account, user, name, field_name)
  role_uuid = SecureRandom.uuid
  template = Template.create!(account:, author: user, name:, submitters: [{ 'name' => 'Kunde', 'uuid' => role_uuid }],
                              fields: [], schema: [])
  blob = ActiveStorage::Blob.create_and_upload!(io: ci_pdf(name), filename: 'ci-vertrag.pdf', content_type: 'application/pdf')
  attachment = ActiveStorage::Attachment.create!(blob:, name: :documents, record: template)
  data = attachment.download
  Pdfium::Document.open_io(StringIO.new(data)) { |pdf| Templates::ProcessDocument.call(attachment, data, doc: pdf) }

  template.schema = [{ 'attachment_uuid' => attachment.uuid, 'name' => 'ci-vertrag' }]
  template.fields = [{
    'uuid' => SecureRandom.uuid, 'submitter_uuid' => role_uuid, 'name' => field_name, 'type' => 'text',
    'required' => true, 'preferences' => {},
    'areas' => [{ 'x' => 0.1, 'y' => 0.2, 'w' => 0.4, 'h' => 0.04, 'attachment_uuid' => attachment.uuid, 'page' => 0 }]
  }]
  template.save!
  [template, role_uuid]
end

def ci_submitter(account, user, template, role_uuid, email)
  submission = Submission.create!(template:, account_id: account.id, created_by_user: user,
                                  template_fields: template.fields, template_schema: template.schema,
                                  template_submitters: template.submitters)
  Submitter.create!(submission:, account_id: account.id, uuid: role_uuid, email:, name: 'CI Kunde')
end

payment_template, payment_role = ci_template(account, user, 'CI Maklervertrag', 'Provision zahlungspflichtig')
plain_template, plain_role = ci_template(account, user, 'CI Formular ohne Zahlungshinweis', 'Name')

desktop = ci_submitter(account, user, payment_template, payment_role, 'kunde-desktop@example.com')
landscape = ci_submitter(account, user, payment_template, payment_role, 'kunde-quer@example.com')
plain = ci_submitter(account, user, plain_template, plain_role, 'kunde-plain@example.com')

puts JSON.generate('desktop' => desktop.slug, 'landscape' => landscape.slug, 'plain' => plain.slug,
                   'desktop_submission_id' => desktop.submission_id)
