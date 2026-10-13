# frozen_string_literal: true

# Offline-Tests für Beweisprotokoll und Button-Beschriftung des Overlays.
# Aufruf: ruby tests/okorn_evidence_test.rb   (nur Ruby-Standardbibliothek)

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../overrides/config/okorn/button_label'
require_relative '../overrides/config/okorn/evidence'
require_relative '../overrides/config/okorn/evidence_shipper'

FakeSubmission = Struct.new(:template_fields, :template)
FakeTemplate = Struct.new(:fields)
FakeSubmitter = Struct.new(:uuid, :submission, :metadata)

class OkornButtonLabelTest < Minitest::Test
  def submitter(fields, metadata = {}, uuid: 'kunde')
    FakeSubmitter.new(uuid, FakeSubmission.new(fields, nil), metadata)
  end

  def test_no_trigger_returns_nil
    assert_nil OkornButtonLabel.compute(submitter([{ 'submitter_uuid' => 'kunde', 'name' => 'Unterschrift' }]))
  end

  def test_keyword_in_title_uses_default_label
    result = OkornButtonLabel.compute(submitter([{ 'uuid' => 'f1', 'submitter_uuid' => 'kunde', 'title' => 'Zahlungspflichtig unterschreiben' }]))
    assert_equal OkornButtonLabel::DEFAULT_LABEL, result.label
    assert_equal 'keyword', result.trigger
    assert_equal 'f1', result.field_uuid
  end

  def test_keyword_of_other_role_is_ignored
    assert_nil OkornButtonLabel.compute(submitter([{ 'submitter_uuid' => 'makler', 'name' => 'zahlungspflichtig' }]))
  end

  def test_marker_wins_and_supports_both_spellings
    fields = [{ 'submitter_uuid' => 'kunde', 'name' => 'zahlungspflichtig' },
              { 'uuid' => 'f2', 'submitter_uuid' => 'kunde', 'description' => 'Text ##button->Provisionspflichtig beauftragen##' }]
    result = OkornButtonLabel.compute(submitter(fields))
    assert_equal 'Provisionspflichtig beauftragen', result.label
    assert_equal 'marker', result.trigger
    assert_equal 'Eigener Text', OkornButtonLabel.compute(submitter([{ 'submitter_uuid' => 'kunde', 'name' => '##button: Eigener Text##' }])).label
  end

  def test_metadata_payment_notice_and_false_values
    assert_equal 'metadata', OkornButtonLabel.compute(submitter([], { 'payment_notice' => true })).trigger
    assert_nil OkornButtonLabel.compute(submitter([], { 'payment_notice' => false }))
    assert_nil OkornButtonLabel.compute(submitter([], { 'payment_notice' => '  ' }))
  end

  def test_falls_back_to_template_fields
    sub = FakeSubmitter.new('kunde', FakeSubmission.new(nil, FakeTemplate.new([{ 'submitter_uuid' => 'kunde', 'name' => 'zahlungspflichtig' }])), {})
    assert_equal 'keyword', OkornButtonLabel.compute(sub).trigger
  end
end

class OkornEvidenceTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('okorn-evidence')
    ENV['OKORN_EVIDENCE_DIR'] = @dir
    ENV.delete('OKORN_EVIDENCE')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    ENV.delete('OKORN_EVIDENCE_DIR')
  end

  def ref(slug, submission_id)
    { 'slug_sha256' => OkornEvidence.slug_digest(slug), 'submission_id' => submission_id }
  end

  def test_chain_links_entries_through_salted_commitments
    first = OkornEvidence.record('http', { 'status' => 200 })
    second = OkornEvidence.record('form_completed', { submission_id: 180, nested: { flag: false } })

    assert_equal 1, first['seq']
    assert_equal OkornEvidence::GENESIS, first['prev']
    assert_equal first['hash'], second['prev']
    assert_equal 64, second['commit'].size
    assert_equal false, second.dig('data', 'nested', 'flag')
    report = OkornEvidence.verify
    assert report[:ok], report[:errors].inspect
    assert_equal 2, report[:entries]
  end

  def test_detects_modified_deleted_and_inserted_lines
    3.times { |i| OkornEvidence.record('http', { 'n' => i }) }
    file = Dir.glob(File.join(@dir, 'evidence-*.jsonl')).first
    lines = File.readlines(file)

    File.write(file, lines[0] + lines[1].sub('"n":1', '"n":9') + lines[2])
    assert_match(/passen nicht zum commit/, OkornEvidence.verify[:errors].join)

    File.write(file, lines[0] + lines[1].sub('"event":"http"', '"event":"xxxx"') + lines[2])
    assert_match(/hash stimmt nicht/, OkornEvidence.verify[:errors].join)

    File.write(file, lines[0] + lines[2])
    errors = OkornEvidence.verify[:errors].join("\n")
    assert_match(/seq 3 erwartet 2/, errors)
    assert_match(/prev passt nicht/, errors)
  end

  def test_head_file_is_only_a_cache_and_days_roll_over
    OkornEvidence.record('a', {}, now: Time.utc(2026, 10, 7, 23, 59, 59))
    File.write(File.join(@dir, 'chain_head.json'), '{"seq":99,"hash":"kaputt"}')
    OkornEvidence.record('b', {}, now: Time.utc(2026, 10, 8, 0, 0, 1))

    assert_equal 2, Dir.glob(File.join(@dir, 'evidence-*.jsonl')).size
    assert OkornEvidence.verify[:ok]
  end

  def test_torn_last_line_is_quarantined_and_chain_continues
    OkornEvidence.record('a', {})
    file = Dir.glob(File.join(@dir, 'evidence-*.jsonl')).first
    File.open(file, 'a') { |f| f.write('{"v":2,"seq":2,"halb') }

    entry = OkornEvidence.record('b', {})
    events = OkornEvidence.entries.map { |e| e['event'] }.to_a
    assert_equal %w[a recovered_partial_write b], events
    assert_equal 3, entry['seq']
    assert OkornEvidence.verify[:ok], OkornEvidence.verify[:errors].inspect
    assert_equal 1, Dir.glob(File.join(@dir, 'quarantine', '*.part')).size
  end

  def test_raw_archive_is_hashed_and_tamper_evident
    raw = OkornEvidence.store_raw('mail', "Subject: Kopie\r\n\r\nPDF", extension: 'eml')
    OkornEvidence.record('mail', { 'raw' => raw })
    assert OkornEvidence.verify[:ok]

    path = File.join(@dir, raw['path'])
    File.chmod(0o640, path)
    File.write(path, 'manipuliert')
    assert_match(/Archivdatei verändert/, OkornEvidence.verify[:errors].join)
  end

  def test_export_redacts_foreign_entries_and_ignores_client_supplied_ids
    OkornEvidence.record('http', { 'submitter' => ref('aaa', 180) })
    OkornEvidence.record('http', { 'submitter' => ref('bbb', 181), 'client' => { 'submission_id' => 180 } })
    OkornEvidence.record('mail', { 'submitter' => ref('aaa', 180) })
    OkornEvidence.record('http', { 'file' => { 'attached_to' => [{ 'submission_id' => 180 }] } })

    export = OkornEvidence.export(submission_id: 180)
    assert_equal 3, export['matching']
    assert_equal 4, export['chain'].size, 'Kette vollständig, fremde Einträge nur geschwärzt'
    foreign = export['chain'][1]
    refute foreign.key?('data')
    refute foreign.key?('salt')
    assert_equal OkornEvidence.entry_hash(foreign), foreign['hash'], 'geschwärzter Eintrag bleibt nachrechenbar'
    assert_equal 1, OkornEvidence.export(submitter_slug: 'bbb')['matching']
    assert export['verify'][:ok]
  end

  def test_redaction_after_retention_keeps_the_chain_valid
    raw = OkornEvidence.store_raw('mail', 'alt', extension: 'eml', now: Time.utc(2020, 1, 1))
    OkornEvidence.record('mail', { 'raw' => raw }, now: Time.utc(2020, 1, 1))
    OkornEvidence.record('http', { 'x' => 1 }, now: Time.utc(2026, 1, 1))

    assert_equal 1, OkornEvidence.redact_before!(Time.utc(2021, 1, 1))
    refute File.exist?(File.join(@dir, raw['path']))
    report = OkornEvidence.verify
    assert report[:ok], report[:errors].inspect
    assert_equal 1, report[:redacted]
  end

  def test_concurrent_writers_keep_a_valid_chain
    threads = 8.times.map { |t| Thread.new { 25.times { |i| OkornEvidence.record('http', { 't' => t, 'i' => i }) } } }
    threads.each(&:join)

    report = OkornEvidence.verify
    assert report[:ok], report[:errors].first(3).inspect
    assert_equal 200, report[:entries]
  end

  def test_invalid_utf8_from_headers_is_recorded_not_dropped
    entry = OkornEvidence.record('http', { 'user_agent' => "Mozilla/5.0 \xFF".b, 'name' => "caf\xC3\xA9".b })
    refute_nil entry
    assert_equal 'café', entry.dig('data', 'name')
    assert OkornEvidence.verify[:ok]
  end

  def test_disabled_and_failing_writes_never_raise
    ENV['OKORN_EVIDENCE'] = 'off'
    assert_nil OkornEvidence.record('http', {})
    ENV.delete('OKORN_EVIDENCE')

    ENV['OKORN_EVIDENCE_DIR'] = File.join(@dir, 'datei')
    File.write(ENV['OKORN_EVIDENCE_DIR'], 'kein Verzeichnis')
    assert_nil OkornEvidence.record('http', {})
  end

  def test_long_strings_are_truncated
    entry = OkornEvidence.record('http', { 'ua' => 'x' * 5000 })
    assert_operator entry.dig('data', 'ua').length, :<, 2100
  end
end

class OkornEvidenceShipperTest < Minitest::Test
  class FakeClient
    attr_reader :puts

    def initialize
      @puts = []
    end

    def put_object(**params)
      @puts << params
    end
  end

  def setup
    @dir = Dir.mktmpdir('okorn-ship')
    ENV['OKORN_EVIDENCE_DIR'] = @dir
    ENV['OKORN_EVIDENCE_S3_BUCKET'] = 'okorn-test'
    ENV['OKORN_EVIDENCE_S3_ACCESS_KEY'] = 'id'
    ENV['OKORN_EVIDENCE_S3_SECRET_KEY'] = 'secret'
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %w[OKORN_EVIDENCE_DIR OKORN_EVIDENCE_S3_BUCKET OKORN_EVIDENCE_S3_ACCESS_KEY OKORN_EVIDENCE_S3_SECRET_KEY].each { |k| ENV.delete(k) }
  end

  def test_ships_closed_days_once_with_object_lock_and_compliance_anchor
    OkornEvidence.record('http', {}, now: Time.utc(2026, 10, 7, 10))
    raw = OkornEvidence.store_raw('mail', 'eml', extension: 'eml', now: Time.utc(2026, 10, 7, 10))
    OkornEvidence.record('mail', { 'raw' => raw }, now: Time.utc(2026, 10, 7, 10))
    OkornEvidence.record('http', {}, now: Time.utc(2026, 10, 8, 9))

    client = FakeClient.new
    now = Time.utc(2026, 10, 8, 12)
    result = OkornEvidence::Shipper.run(now:, client:)

    data = client.puts.reject { |p| p[:key].include?('/anchors/') }
    anchor = client.puts.find { |p| p[:key].include?('/anchors/') }
    keys = data.map { |p| p[:key] }
    assert_includes keys, 'sign.okorn.biz/evidence-2026-10-07.jsonl'
    assert(keys.any? { |k| k.start_with?('sign.okorn.biz/mail/2026-10-07/') })
    refute_includes keys, 'sign.okorn.biz/evidence-2026-10-08.jsonl'
    assert(data.all? { |p| p[:object_lock_mode] == 'GOVERNANCE' && p[:object_lock_retain_until_date] > now })
    assert_equal 'COMPLIANCE', anchor[:object_lock_mode]
    assert_equal 3, JSON.parse(anchor[:body]).dig('head', 'seq')
    assert_equal 2, result[:shipped].size

    second = FakeClient.new
    OkornEvidence::Shipper.run(now: now + 60, client: second)
    assert_equal 1, second.puts.size, 'nur der neue Anker, keine erneuten Dateien'
  end

  def test_changed_file_is_never_overwritten
    OkornEvidence.record('http', {}, now: Time.utc(2026, 10, 7, 10))
    OkornEvidence::Shipper.run(now: Time.utc(2026, 10, 8, 12), client: FakeClient.new)
    file = File.join(@dir, 'evidence-2026-10-07.jsonl')
    File.write(file, File.read(file).sub('"http"', '"xxxx"'))

    client = FakeClient.new
    OkornEvidence::Shipper.run(now: Time.utc(2026, 10, 9, 12), client:)
    changed = client.puts.map { |p| p[:key] }.find { |k| k.include?('evidence-2026-10-07.jsonl.changed-') }
    refute_nil changed
    refute(client.puts.any? { |p| p[:key] == 'sign.okorn.biz/evidence-2026-10-07.jsonl' })
    assert(OkornEvidence.entries.any? { |e| e['event'] == 'evidence_changed_after_ship' })
  end

  def test_not_configured_is_a_noop
    ENV.delete('OKORN_EVIDENCE_S3_BUCKET')
    assert_equal :not_configured, OkornEvidence::Shipper.run(client: FakeClient.new)[:skipped]
  end
end
