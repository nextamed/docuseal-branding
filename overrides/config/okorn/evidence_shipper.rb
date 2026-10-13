# frozen_string_literal: true

# OKorn-Overlay: Auslagerung des Beweisprotokolls in S3-kompatiblen Speicher
# mit Object Lock (z. B. Wasabi). Abgeschlossene Tagesdateien und Mail-Archive
# werden einmal hochgeladen und gegen Löschen/Überschreiben gesperrt; bei jedem
# Lauf kommt zusätzlich ein Anker mit dem aktuellen Kettenkopf dazu. Damit lässt
# sich später zeigen, dass die lokale Kette seit dem Anker nicht neu
# geschrieben wurde.
#
# Aufruf (z. B. täglich als Coolify Scheduled Task im DocuSeal-Container):
#   /app/bin/bundle exec rails runner 'OkornEvidence::Shipper.run'
#
# Konfiguration über ENV (fehlt Bucket oder Schlüssel, passiert nichts):
#   OKORN_EVIDENCE_S3_BUCKET, OKORN_EVIDENCE_S3_ENDPOINT, OKORN_EVIDENCE_S3_REGION,
#   OKORN_EVIDENCE_S3_ACCESS_KEY_ID, OKORN_EVIDENCE_S3_SECRET_ACCESS_KEY,
#   OKORN_EVIDENCE_S3_PREFIX (Standard: sign.okorn.biz/),
#   OKORN_EVIDENCE_LOCK_MODE (GOVERNANCE|COMPLIANCE, Standard GOVERNANCE),
#   OKORN_EVIDENCE_LOCK_DAYS (Standard 2192 = 6 Jahre, 0 = ohne Sperre)

require 'base64'
require 'digest'
require 'json'
require 'time'

module OkornEvidence
  module Shipper
    module_function

    # Akzeptiert die Namen, die der Wasabi-Zugang in Coolify anlegt
    # (Präfix OKORN_EVIDENCE_S3_, z. B. ..._ACCESS_KEY oder ..._ACCESS_KEY_ID).
    def env(*suffixes)
      suffixes.map { |suffix| ENV["OKORN_EVIDENCE_S3_#{suffix}"].to_s.strip }.find { |value| !value.empty? }.to_s
    end

    def config
      bucket = env('BUCKET')
      key_id = env('ACCESS_KEY_ID', 'ACCESS_KEY', 'KEY_ID', 'KEY')
      secret = env('SECRET_ACCESS_KEY', 'SECRET_KEY', 'SECRET')
      return if bucket.empty? || key_id.empty? || secret.empty?

      region = env('REGION')
      {
        bucket:,
        endpoint: env('ENDPOINT', 'URL'),
        region: region.empty? ? 'eu-central-2' : region,
        access_key_id: key_id,
        secret_access_key: secret,
        prefix: ENV.fetch('OKORN_EVIDENCE_S3_PREFIX', 'sign.okorn.biz/'),
        lock_mode: ENV.fetch('OKORN_EVIDENCE_LOCK_MODE', 'GOVERNANCE').upcase,
        lock_days: Integer(ENV.fetch('OKORN_EVIDENCE_LOCK_DAYS', '2192'))
      }
    end

    def run(now: Time.now.utc, client: nil, base: OkornEvidence.dir)
      cfg = config
      unless cfg
        OkornEvidence.report_error(RuntimeError.new('Shipper nicht konfiguriert (OKORN_EVIDENCE_S3_*)'))
        return { shipped: [], skipped: :not_configured }
      end

      client ||= build_client(cfg)
      manifest = load_manifest(base)
      shipped = []
      today = "evidence-#{now.strftime('%Y-%m-%d')}.jsonl"

      shippable_files(base).each do |rel|
        next if File.basename(rel) == today

        path = File.join(base, rel)
        sha = Digest::SHA256.file(path).hexdigest
        previous = manifest[rel]
        next if previous && previous['sha256'] == sha

        put(client, cfg, rel, File.binread(path), now:, metadata: { 'sha256' => sha })
        manifest[rel] = { 'sha256' => sha, 'shipped_at' => now.iso8601,
                          'changed_after_ship' => previous ? previous['sha256'] : nil }.compact
        shipped << rel
      end

      anchor = { 'anchored_at' => now.iso8601(6), 'head' => OkornEvidence.read_head(base),
                 'verify' => OkornEvidence.verify(base), 'files' => manifest }
      anchor_key = "anchors/#{now.strftime('%Y-%m-%dT%H%M%S')}Z-head.json"
      put(client, cfg, anchor_key, JSON.pretty_generate(anchor), now:, content_type: 'application/json')

      save_manifest(base, manifest)
      OkornEvidence.record('evidence_shipped', { 'files' => shipped, 'anchor' => anchor_key,
                                                 'bucket' => cfg[:bucket], 'lock_mode' => cfg[:lock_mode],
                                                 'lock_days' => cfg[:lock_days] }, now:)

      { shipped:, anchor: anchor_key }
    end

    def shippable_files(base)
      Dir.glob(File.join(base, '{evidence-*.jsonl,mail/**/*.eml}')).sort.map { |path| path.delete_prefix("#{base}/") }
    end

    def put(client, cfg, rel, body, now:, metadata: {}, content_type: nil)
      params = {
        bucket: cfg[:bucket],
        key: "#{cfg[:prefix]}#{rel}",
        body:,
        content_md5: Base64.strict_encode64(Digest::MD5.digest(body)),
        metadata:
      }
      params[:content_type] = content_type if content_type

      if cfg[:lock_days].positive?
        params[:object_lock_mode] = cfg[:lock_mode]
        params[:object_lock_retain_until_date] = now + (cfg[:lock_days] * 86_400)
      end

      client.put_object(**params)
    end

    def build_client(cfg)
      require 'aws-sdk-s3'

      options = { region: cfg[:region], access_key_id: cfg[:access_key_id],
                  secret_access_key: cfg[:secret_access_key], force_path_style: true }
      unless cfg[:endpoint].empty?
        options[:endpoint] = cfg[:endpoint].match?(%r{\Ahttps?://}) ? cfg[:endpoint] : "https://#{cfg[:endpoint]}"
      end

      Aws::S3::Client.new(**options)
    end

    def manifest_path(base)
      File.join(base, 'shipped.json')
    end

    def load_manifest(base)
      JSON.parse(File.read(manifest_path(base)))
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end

    def save_manifest(base, manifest)
      tmp = "#{manifest_path(base)}.tmp"
      File.write(tmp, JSON.pretty_generate(manifest))
      File.rename(tmp, manifest_path(base))
    end
  end
end
