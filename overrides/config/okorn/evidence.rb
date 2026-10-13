# frozen_string_literal: true

# OKorn-Overlay (github.com/nextamed/docuseal-branding): Beweisprotokoll.
#
# Schreibt nur mit, greift nie in den Signaturablauf ein und darf ihn nie
# blockieren: jeder Fehler wird geloggt und verschluckt.
#
# Ablage: <WORKDIR>/okorn-evidence (persistentes DocuSeal-Volume)
#   evidence-YYYY-MM-DD.jsonl   ein Eintrag pro Zeile, Tag in UTC
#   chain_head.json             letzter Eintrag (seq, hash)
#   mail/YYYY-MM-DD/*.eml       Archivkopien ausgehender Unterzeichner-Mails
#
# Jeder Eintrag enthält den Hash des Vorgängers ("prev") und seinen eigenen
# SHA-256 über die kanonische JSON-Form ohne "hash". Eine nachträgliche
# Änderung, Einfügung oder Löschung bricht die Kette; verify meldet sie.
# Gegen das Neuschreiben der ganzen Kette sichert die Auslagerung in
# schreibgeschützten Speicher (Shipper, Object Lock).

require 'json'
require 'digest'
require 'fileutils'
require 'time'
require 'socket'

module OkornEvidence
  SCHEMA = 1
  GENESIS = '0' * 64
  MAX_STRING = 2_000
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

  def record(event, data = {}, now: Time.now.utc)
    return unless enabled?

    MUTEX.synchronize do
      FileUtils.mkdir_p(dir)

      File.open(File.join(dir, '.lock'), File::RDWR | File::CREAT, 0o640) do |lock|
        lock.flock(File::LOCK_EX)

        head = read_head
        entry = {
          'v' => SCHEMA,
          'seq' => head['seq'] + 1,
          'ts' => now.utc.iso8601(6),
          'event' => event.to_s,
          'data' => sanitize(data),
          'meta' => meta,
          'prev' => head['hash']
        }
        entry['hash'] = entry_hash(entry)

        line = "#{canonical_json(entry)}\n"
        File.open(day_path(now), 'a', 0o640) do |file|
          file.write(line)
          file.flush
          file.fsync
        end

        write_head(entry, day_path(now))
        log_line(line)

        entry
      end
    end
  rescue StandardError => e
    report_error(e)
    nil
  end

  # Speichert Rohdaten (z. B. eine E-Mail) unveränderlich neben der Kette und
  # liefert Pfad und SHA-256 für den Kettenrecord.
  def store_raw(kind, bytes, extension:, now: Time.now.utc)
    sha = Digest::SHA256.hexdigest(bytes)
    rel = File.join(kind.to_s, now.strftime('%Y-%m-%d'), "#{now.strftime('%H%M%S%6N')}-#{sha[0, 16]}.#{extension}")
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

  def verify(base = dir)
    errors = []
    prev = GENESIS
    seq = 0
    count = 0
    first_ts = nil
    last_ts = nil

    Dir.glob(File.join(base, 'evidence-*.jsonl')).sort.each do |path|
      File.foreach(path).with_index(1) do |line, lineno|
        where = "#{File.basename(path)}:#{lineno}"
        entry = JSON.parse(line)

        errors << "#{where} seq #{entry['seq']} erwartet #{seq + 1}" if entry['seq'] != seq + 1
        errors << "#{where} prev passt nicht zum Vorgänger" if entry['prev'] != prev
        errors << "#{where} hash stimmt nicht (Eintrag verändert)" if entry['hash'] != entry_hash(entry)

        raw = entry.dig('data', 'raw')
        errors.concat(verify_raw(base, raw, where)) if raw.is_a?(Hash) && raw['path']

        prev = entry['hash']
        seq = entry['seq'].to_i
        count += 1
        first_ts ||= entry['ts']
        last_ts = entry['ts']
      rescue JSON::ParserError
        errors << "#{where} keine gültige JSON-Zeile"
      end
    end

    head = read_head(base)
    if count.positive? && (head['hash'] != prev || head['seq'] != seq)
      errors << "chain_head.json passt nicht zum letzten Eintrag (seq #{head['seq']} statt #{seq})"
    end

    { ok: errors.empty?, entries: count, first_ts:, last_ts:, last_seq: seq, last_hash: prev, errors: }
  end

  def entries(base = dir)
    Dir.glob(File.join(base, 'evidence-*.jsonl')).sort.lazy.flat_map do |path|
      File.foreach(path).map { |line| JSON.parse(line) }
    end
  end

  # Alle Einträge zu einem Vorgang (Submission-ID) oder Unterzeichner-Slug,
  # dazu die Prüfung der Gesamtkette. Für Gericht/Anwalt: zusammen mit den
  # referenzierten .eml-Dateien und dem ausgelagerten chain_head weitergeben.
  def export(submission_id: nil, submitter_slug: nil, base: dir)
    wanted_id = submission_id&.to_i
    selected = entries(base).select do |entry|
      ids = collect_values(entry['data'], %w[submission_id])
      slugs = collect_values(entry['data'], %w[slug submitter_slug])

      (wanted_id && ids.map(&:to_i).include?(wanted_id)) || (submitter_slug && slugs.include?(submitter_slug))
    end.to_a

    { 'exported_at' => Time.now.utc.iso8601, 'filter' => { 'submission_id' => wanted_id, 'submitter_slug' => submitter_slug }.compact,
      'verify' => verify(base), 'entries' => selected }
  end

  def entry_hash(entry)
    Digest::SHA256.hexdigest(canonical_json(entry.reject { |key, _| key == 'hash' }))
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

        acc[key.to_s] = sanitize(item, depth + 1)
      end
    when Array then value.first(200).map { |item| sanitize(item, depth + 1) }
    when String then value.length > MAX_STRING ? "#{value[0, MAX_STRING]}…[gekürzt]" : value
    when Symbol then value.to_s
    when Integer, Float, TrueClass, FalseClass then value
    when Time then value.utc.iso8601(6)
    else
      value.respond_to?(:iso8601) ? value.iso8601 : value.to_s[0, MAX_STRING]
    end
  end

  def meta
    {
      'host' => Socket.gethostname,
      'pid' => Process.pid,
      'overlay_revision' => ENV['OKORN_OVERLAY_REVISION'],
      'docuseal_version' => ENV['OKORN_DOCUSEAL_VERSION']
    }.compact
  end

  def day_path(now)
    File.join(dir, "evidence-#{now.utc.strftime('%Y-%m-%d')}.jsonl")
  end

  def head_path(base = dir)
    File.join(base, 'chain_head.json')
  end

  def read_head(base = dir)
    head = JSON.parse(File.read(head_path(base)))
    return head if head['seq'].is_a?(Integer) && head['hash'].is_a?(String)

    rebuild_head(base)
  rescue Errno::ENOENT, JSON::ParserError
    rebuild_head(base)
  end

  # Fallback, falls chain_head.json fehlt oder kaputt ist: letzter Eintrag der
  # jüngsten Tagesdatei.
  def rebuild_head(base = dir)
    last = Dir.glob(File.join(base, 'evidence-*.jsonl')).max
    line = last && File.readlines(last).reverse.find { |item| !item.strip.empty? }
    entry = line ? JSON.parse(line) : nil

    entry ? { 'seq' => entry['seq'], 'hash' => entry['hash'] } : { 'seq' => 0, 'hash' => GENESIS }
  end

  def write_head(entry, file)
    tmp = "#{head_path}.tmp"
    File.write(tmp, JSON.generate('seq' => entry['seq'], 'hash' => entry['hash'], 'ts' => entry['ts'],
                                  'file' => File.basename(file)))
    File.rename(tmp, head_path)
  end

  def verify_raw(base, raw, where)
    path = File.join(base, raw['path'])
    return ["#{where} Archivdatei fehlt: #{raw['path']}"] unless File.exist?(path)
    return ["#{where} Archivdatei verändert: #{raw['path']}"] if Digest::SHA256.file(path).hexdigest != raw['sha256']

    []
  end

  def collect_values(value, keys, acc = [])
    case value
    when Hash
      value.each do |key, item|
        acc << item if keys.include?(key) && !item.nil?
        collect_values(item, keys, acc)
      end
    when Array then value.each { |item| collect_values(item, keys, acc) }
    end
    acc
  end

  def log_line(line)
    return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

    ::Rails.logger.info("[okorn-evidence] #{line.chomp}")
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
