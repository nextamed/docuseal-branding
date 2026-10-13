# frozen_string_literal: true

# OKorn-Overlay (github.com/nextamed/docuseal-branding): Beweisprotokoll.
#
# Schreibt nur mit, greift nie in den Signaturablauf ein und darf ihn nie
# blockieren: jeder Fehler wird geloggt und verschluckt.
#
# Ablage: <WORKDIR>/okorn-evidence (persistentes DocuSeal-Volume)
#   evidence-YYYY-MM-DD.jsonl   ein Eintrag pro Zeile, Tag in UTC
#   chain_head.json             Zwischenspeicher des letzten Eintrags; maßgeblich
#                               ist immer die letzte vollständige Zeile
#   mail/YYYY-MM-DD/*.eml       Archivkopien ausgehender Unterzeichner-Mails
#   quarantine/                 Reste abgebrochener Schreibvorgänge
#
# Kettenformat (v2): Verkettet wird nicht der Klartext, sondern ein gesalzener
# Hash der Daten ("commit" = SHA-256(salt + kanonisches JSON von data)).
# "hash" = SHA-256 über {v, seq, ts, event, meta, commit, prev}. Dadurch
#   - lassen sich fremde Einträge beim Export schwärzen (data und salt weg,
#     commit bleibt) und die Kette bleibt trotzdem nachrechenbar,
#   - lassen sich Daten nach Ablauf der Aufbewahrung löschen (redact_before!),
#     ohne die Kette zu brechen.
#
# Aussagekraft: intern konsistent; Änderungen an Einträgen vor dem letzten
# ausgelagerten Anker (Shipper, Object Lock) sind nachweisbar. Abschneiden
# oder Neuschreiben nach dem letzten Anker ist nur durch häufige Anker
# begrenzbar.

require 'json'
require 'digest'
require 'fileutils'
require 'time'
require 'socket'
require 'securerandom'

module OkornEvidence
  SCHEMA = 2
  GENESIS = '0' * 64
  MAX_STRING = 2_000
  HASHED_KEYS = %w[v seq ts event meta commit prev].freeze
  MUTEX = Mutex.new

  module_function

  def enabled?
    ENV.fetch('OKORN_EVIDENCE', 'on') != 'off'
  end

  def dir
    custom = ENV['OKORN_EVIDENCE_DIR'].to_s.strip
    return custom unless custom.empty?

    File.join(ENV.fetch('WORKDIR', '/data/docuseal'), 'okorn-evidence')
  end

  # now: nur für Tests; im Betrieb wird die Zeit erst unter der Sperre gelesen,
  # damit Reihenfolge der Einträge und Tagesdatei zusammenpassen.
  def record(event, data = {}, now: nil)
    return unless enabled?

    with_lock(File::LOCK_EX) do
      time = (now || Time.now).utc
      repair_tail!(time)
      append(event, data, time)
    end
  rescue StandardError => e
    report_error(e)
    nil
  end

  def with_lock(mode)
    MUTEX.synchronize do
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, '.lock'), File::RDWR | File::CREAT, 0o640) do |lock|
        lock.flock(mode)
        yield
      end
    end
  end

  def append(event, data, time)
    head = current_head
    salt = SecureRandom.hex(16)
    clean = sanitize(data)
    entry = {
      'v' => SCHEMA, 'seq' => head['seq'] + 1, 'ts' => time.iso8601(6), 'event' => event.to_s,
      'meta' => meta, 'commit' => commitment(salt, clean), 'prev' => head['hash']
    }
    entry['hash'] = entry_hash(entry)
    entry['data'] = clean
    entry['salt'] = salt

    path = day_path(time)
    File.open(path, 'a', 0o640) do |file|
      file.write("#{canonical_json(entry)}\n")
      file.flush
      file.fsync
    end
    write_head(entry, path)
    log_line(entry)

    entry
  end

  # Entfernt eine abgebrochene letzte Zeile (Absturz mitten im Schreiben),
  # legt sie in quarantine/ ab und protokolliert den Vorgang in der Kette.
  def repair_tail!(time)
    path = Dir.glob(File.join(dir, 'evidence-*.jsonl')).max
    return unless path && File.size?(path)

    fragment = nil
    File.open(path, 'r+') do |file|
      file.seek(-1, IO::SEEK_END)
      next if file.read(1) == "\n"

      content = File.binread(path)
      keep = content.rindex("\n") ? content.rindex("\n") + 1 : 0
      fragment = content.byteslice(keep..)
      file.truncate(keep)
    end
    return unless fragment

    quarantine = File.join(dir, 'quarantine', "#{File.basename(path)}.#{time.strftime('%Y%m%dT%H%M%S%6N')}.part")
    FileUtils.mkdir_p(File.dirname(quarantine))
    File.binwrite(quarantine, fragment)
    append('recovered_partial_write', { 'file' => File.basename(path), 'bytes' => fragment.bytesize,
                                        'sha256' => Digest::SHA256.hexdigest(fragment),
                                        'quarantine' => quarantine.delete_prefix("#{dir}/") }, time)
  end

  # Speichert Rohdaten (z. B. eine E-Mail) schreibgeschützt (0440) neben der
  # Kette und liefert Pfad und SHA-256 für den Kettenrecord.
  def store_raw(kind, bytes, extension:, now: nil)
    time = (now || Time.now).utc
    sha = Digest::SHA256.hexdigest(bytes)
    rel = File.join(kind.to_s, time.strftime('%Y-%m-%d'), "#{time.strftime('%H%M%S%6N')}-#{sha[0, 16]}.#{extension}")
    path = File.join(dir, rel)

    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o440) do |file|
      file.write(bytes)
      file.flush
      file.fsync
    end

    { 'path' => rel, 'sha256' => sha, 'bytes' => bytes.bytesize }
  rescue StandardError => e
    report_error(e)
    { 'error' => e.class.name, 'sha256' => sha }.compact
  end

  # Prüft die ganze Kette unter einer geteilten Sperre (Schnappschuss).
  def verify(base = dir)
    return verify_unlocked(base) unless base == dir && File.directory?(base)

    with_lock(File::LOCK_SH) { verify_unlocked(base) }
  end

  def verify_unlocked(base)
    errors = []
    prev = GENESIS
    seq = 0
    count = 0
    redacted = 0
    first_ts = nil
    last_ts = nil

    Dir.glob(File.join(base, 'evidence-*.jsonl')).sort.each do |path|
      File.foreach(path).with_index(1) do |line, lineno|
        where = "#{File.basename(path)}:#{lineno}"
        entry = JSON.parse(line)

        errors << "#{where} seq #{entry['seq']} erwartet #{seq + 1}" if entry['seq'] != seq + 1
        errors << "#{where} prev passt nicht zum Vorgänger" if entry['prev'] != prev
        errors << "#{where} hash stimmt nicht (Eintrag verändert)" if entry['hash'] != entry_hash(entry)

        if entry.key?('data')
          errors << "#{where} Daten passen nicht zum commit (Inhalt verändert)" if entry['commit'] != commitment(entry['salt'], entry['data'])
          raw = entry.dig('data', 'raw')
          errors.concat(verify_raw(base, raw, where)) if raw.is_a?(Hash) && raw['path']
        else
          redacted += 1
        end

        prev = entry['hash']
        seq = entry['seq'].to_i
        count += 1
        first_ts ||= entry['ts']
        last_ts = entry['ts']
      rescue JSON::ParserError
        errors << "#{where} keine gültige JSON-Zeile"
      end
    end

    { ok: errors.empty?, entries: count, redacted:, first_ts:, last_ts:, last_seq: seq, last_hash: prev, errors: }
  end

  def entries(base = dir)
    Dir.glob(File.join(base, 'evidence-*.jsonl')).sort.lazy.flat_map do |path|
      File.foreach(path).map { |line| JSON.parse(line) }
    end
  end

  # Export zu einem Vorgang (Submission-ID) oder Unterzeichner-Slug. Fremde
  # Einträge werden geschwärzt (ohne data/salt), bleiben aber in der Kette,
  # damit Dritte die Verkettung bis zum Anker nachrechnen können.
  def export(submission_id: nil, submitter_slug: nil, base: dir)
    wanted_id = submission_id&.to_i
    wanted_slug = submitter_slug && slug_digest(submitter_slug)

    chain = entries(base).map do |entry|
      next entry if relevant?(entry, wanted_id, wanted_slug)

      entry.reject { |key, _| %w[data salt].include?(key) }
    end.to_a

    { 'exported_at' => Time.now.utc.iso8601, 'schema' => SCHEMA,
      'filter' => { 'submission_id' => wanted_id, 'slug_sha256' => wanted_slug }.compact,
      'verify' => verify(base), 'matching' => chain.count { |entry| entry.key?('data') }, 'chain' => chain }
  end

  def relevant?(entry, wanted_id, wanted_slug)
    data = entry['data']
    return false unless data.is_a?(Hash)

    refs = [data['submitter'], data['submission']].compact
    refs += Array(data.dig('file', 'attached_to'))
    refs.select! { |ref| ref.is_a?(Hash) }

    (wanted_id && refs.any? { |ref| ref['submission_id'].to_i == wanted_id }) ||
      (wanted_slug && refs.any? { |ref| ref['slug_sha256'] == wanted_slug })
  end

  # Schwärzt Einträge vor dem Stichtag (Ablauf der Aufbewahrung): data und salt
  # werden entfernt, referenzierte .eml-Dateien gelöscht. Die Kette bleibt prüfbar.
  def redact_before!(time, base: dir)
    cutoff = time.utc.iso8601(6)
    removed = 0

    with_lock(File::LOCK_EX) do
      Dir.glob(File.join(base, 'evidence-*.jsonl')).sort.each do |path|
        lines = File.readlines(path).map do |line|
          entry = JSON.parse(line)
          next line unless entry['ts'] < cutoff && entry.key?('data')

          raw = entry.dig('data', 'raw', 'path')
          FileUtils.rm_f(File.join(base, raw)) if raw
          removed += 1
          "#{canonical_json(entry.reject { |key, _| %w[data salt].include?(key) })}\n"
        end
        tmp = "#{path}.tmp"
        File.write(tmp, lines.join)
        File.rename(tmp, path)
      end
      append('redacted_before', { 'cutoff' => cutoff, 'entries' => removed }, Time.now.utc)
    end

    removed
  end

  def commitment(salt, data)
    Digest::SHA256.hexdigest("#{salt}#{canonical_json(data)}")
  end

  def entry_hash(entry)
    Digest::SHA256.hexdigest(canonical_json(entry.slice(*HASHED_KEYS)))
  end

  def slug_digest(slug)
    Digest::SHA256.hexdigest("okorn-slug:#{slug}")
  end

  def canonical_json(value)
    JSON.generate(canonicalize(value))
  end

  def canonicalize(value)
    case value
    when Hash then value.map { |key, item| [key.to_s, canonicalize(item)] }.sort_by(&:first).to_h
    when Array then value.map { |item| canonicalize(item) }
    else value
    end
  end

  def sanitize(value, depth = 0)
    return '[zu tief]' if depth > 6

    case value
    when Hash
      value.each_with_object({}) do |(key, item), acc|
        next if item.nil?

        acc[clean_string(key.to_s)] = sanitize(item, depth + 1)
      end
    when Array then value.first(200).map { |item| sanitize(item, depth + 1) }
    when String then truncate(clean_string(value))
    when Symbol then value.to_s
    when Integer, Float, TrueClass, FalseClass then value
    when Time then value.utc.iso8601(6)
    else
      truncate(clean_string(value.respond_to?(:iso8601) ? value.iso8601 : value.to_s))
    end
  end

  def clean_string(value)
    string = value.dup.force_encoding(Encoding::UTF_8)
    string.valid_encoding? ? string : string.scrub('�')
  end

  def truncate(string, max = MAX_STRING)
    string.length > max ? "#{string[0, max]}…[gekürzt]" : string
  end

  def meta
    {
      'host' => Socket.gethostname,
      'pid' => Process.pid,
      'overlay_revision' => ENV['OKORN_OVERLAY_REVISION'],
      'docuseal_version' => ENV['OKORN_DOCUSEAL_VERSION']
    }.compact
  end

  def day_path(time)
    File.join(dir, "evidence-#{time.utc.strftime('%Y-%m-%d')}.jsonl")
  end

  def head_path(base = dir)
    File.join(base, 'chain_head.json')
  end

  def read_head(base = dir)
    JSON.parse(File.read(head_path(base)))
  rescue Errno::ENOENT, JSON::ParserError
    last_entry_head(base)
  end

  # Maßgeblich ist die letzte vollständige Zeile der jüngsten Tagesdatei;
  # chain_head.json ist nur Zwischenspeicher.
  def current_head(base = dir)
    last_entry_head(base)
  end

  def last_entry_head(base = dir)
    last = Dir.glob(File.join(base, 'evidence-*.jsonl')).max
    return { 'seq' => 0, 'hash' => GENESIS } unless last

    line = File.readlines(last).reverse.find { |item| item.end_with?("\n") && !item.strip.empty? }
    entry = line && JSON.parse(line)
    entry ? { 'seq' => entry['seq'], 'hash' => entry['hash'], 'ts' => entry['ts'] } : { 'seq' => 0, 'hash' => GENESIS }
  end

  def write_head(entry, file)
    tmp = "#{head_path}.tmp"
    File.open(tmp, 'w', 0o640) do |io|
      io.write(JSON.generate('seq' => entry['seq'], 'hash' => entry['hash'], 'ts' => entry['ts'],
                             'file' => File.basename(file)))
      io.flush
      io.fsync
    end
    File.rename(tmp, head_path)
  end

  def verify_raw(base, raw, where)
    path = File.join(base, raw['path'])
    return ["#{where} Archivdatei fehlt: #{raw['path']}"] unless File.exist?(path)
    return ["#{where} Archivdatei verändert: #{raw['path']}"] if Digest::SHA256.file(path).hexdigest != raw['sha256']

    []
  end

  # Ins Container-Log nur die Kennung, nie den Inhalt.
  def log_line(entry)
    return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

    ::Rails.logger.info("[okorn-evidence] seq=#{entry['seq']} event=#{entry['event']} hash=#{entry['hash']}")
  end

  def report_error(error)
    message = "[okorn-evidence] FEHLER #{error.class}: #{error.message}"

    if defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
      ::Rails.logger.error(message)
    else
      warn(message)
    end
  end
end
