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

  def test_chain_links_entries_and_verifies
    first = OkornEvidence.record('http', { 'slug' => 'abc', 'status' => 200 })
    second = OkornEvidence.record('form_completed', { submission_id: 180, nested: { flag: false } })

    assert_equal 1, first['seq']
    assert_equal OkornEvidence::GENESIS, first['prev']
    assert_equal first['hash'], second['prev']
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
    assert_match(/hash stimmt nicht/, OkornEvidence.verify[:errors].join)

    File.write(file, lines[0] + lines[2])
    errors = OkornEvidence.verify[:errors].join("\n")
    assert_match(/seq 3 erwartet 2/, errors)
    assert_match(/prev passt nicht/, errors)
  end

  def test_survives_missing_head_and_spans_days
    OkornEvidence.record('a', {}, now: Time.utc(2026, 10, 7, 23, 59, 59))
    File.delete(File.join(@dir, 'chain_head.json'))
    OkornEvidence.record('b', {}, now: Time.utc(2026, 10, 8, 0, 0, 1))

    assert_equal 2, Dir.glob(File.join(@dir, 'evidence-*.jsonl')).size
    assert OkornEvidence.verify[:ok]
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

  def test_export_filters_by_submission_and_slug
    OkornEvidence.record('http', { 'submitter' => { 'slug' => 'aaa', 'submission_id' => 180 } })
    OkornEvidence.record('http', { 'submitter' => { 'slug' => 'bbb', 'submission_id' => 181 } })
    OkornEvidence.record('mail', { 'submitter' => { 'slug' => 'aaa', 'submission_id' => 180 } })

    assert_equal 2, OkornEvidence.export(submission_id: 180)['entries'].size
    assert_equal 1, OkornEvidence.export(submitter_slug: 'bbb')['entries'].size
    assert OkornEvidence.export(submission_id: 180)['verify'][:ok]
  end

  def test_concurrent_writers_keep_a_valid_chain
    threads = 8.times.map { |t| Thread.new { 25.times { |i| OkornEvidence.record('http', { 't' => t, 'i' => i }) } } }
    threads.each(&:join)

    report = OkornEvidence.verify
    assert report[:ok], report[:errors].first(3).inspect
    assert_equal 200, report[:entries]
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
    ENV['OKORN_EVIDENCE_S3_ACCESS_KEY_ID'] = 'id'
    ENV['OKORN_EVIDENCE_S3_SECRET_ACCESS_KEY'] = 'secret'
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %w[OKORN_EVIDENCE_DIR OKORN_EVIDENCE_S3_BUCKET OKORN_EVIDENCE_S3_ACCESS_KEY_ID OKORN_EVIDENCE_S3_SECRET_ACCESS_KEY].each { |k| ENV.delete(k) }
  end

  def test_ships_closed_days_once_with_object_lock_and_anchor
    OkornEvidence.record('http', {}, now: Time.utc(2026, 10, 7, 10))
    raw = OkornEvidence.store_raw('mail', 'eml', extension: 'eml', now: Time.utc(2026, 10, 7, 10))
    OkornEvidence.record('mail', { 'raw' => raw }, now: Time.utc(2026, 10, 7, 10))
    OkornEvidence.record('http', {}, now: Time.utc(2026, 10, 8, 9))

    client = FakeClient.new
    now = Time.utc(2026, 10, 8, 12)
    result = OkornEvidence::Shipper.run(now:, client:)

    keys = client.puts.map { |p| p[:key] }
    assert_includes keys, 'sign.okorn.biz/evidence-2026-10-07.jsonl'
    assert(keys.any? { |k| k.start_with?('sign.okorn.biz/mail/2026-10-07/') })
    refute_includes keys, 'sign.okorn.biz/evidence-2026-10-08.jsonl'
    assert(keys.any? { |k| k.start_with?('sign.okorn.biz/anchors/') })
    assert(client.puts.all? { |p| p[:object_lock_mode] == 'GOVERNANCE' && p[:object_lock_retain_until_date] > now })
    assert_equal 2, result[:shipped].size

    second = FakeClient.new
    OkornEvidence::Shipper.run(now: now + 60, client: second)
    assert_equal 1, second.puts.size, 'nur der neue Anker, keine erneuten Dateien'
  end

  def test_not_configured_is_a_noop
    ENV.delete('OKORN_EVIDENCE_S3_BUCKET')
    assert_equal :not_configured, OkornEvidence::Shipper.run(client: FakeClient.new)[:skipped]
  end
end
