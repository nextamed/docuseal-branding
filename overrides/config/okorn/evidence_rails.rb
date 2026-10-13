# frozen_string_literal: true

# OKorn-Overlay: Anbindung des Beweisprotokolls an DocuSeal (Rails).
# Ausschließlich Beobachter (ActiveSupport::Notifications, Mail-Interceptor
# und -Observer): kein Eingriff in Controller, Signaturlogik oder Mailversand.
#
# Protokolliert (nur wenn die Ressource gefunden wurde):
#   http.signing_page    Formularseite tatsächlich gerendert, mit der in die
#                        Seite geschriebenen Beschriftung (Marker aus der View)
#   http.signing_page_other  /s/<slug> lieferte eine andere Seite (2FA, Warten,
#                        abgelaufen, abgelehnt)
#   http.form_completed  erfolgreicher Abschluss (auch über das Einladungsformular)
#   http.form_complete_rejected  Abschlussversuch abgelehnt (Status, Fehler)
#   http.*               Abschlussseite, Download-Links, Datei-Abruf mit Prüfsumme,
#                        Link aus der Kopie-Mail, erneut einreichen, Kopie-Mail
#                        angefordert, Ablehnen, Admin-/API-Änderungen
#   mail_attempt / mail  Mail an den Mailserver übergeben bzw. erfolgreich
#                        übergeben (fehlt "mail" zu einem "mail_attempt", ist der
#                        Versand gescheitert); Unterzeichner-Mails mit .eml
#   button_click         Klick-Nachweis aus dem Browser, an die ausgelieferte
#                        Seite gebunden (signiertes Token)
#
# Signatur-Links (Slugs) werden nur als Hash gespeichert, Pfade maskiert.

require 'digest'
require 'base64'

module OkornEvidence
  module RailsHooks
    SIGNER_CONTROLLERS = %w[
      SubmitFormController SubmitFormCompletedDownloadController SubmitFormDownloadController
      SubmitFormDeclineController SubmitFormDelegateController SubmitFormInviteController
      SubmitFormViewController SubmitFormClickEmailController SubmitFormUploadController
      SubmitFormEmail2fasController SubmitFormDrawSignatureController
      StartFormController StartFormResubmitController StartFormSelfController
      SendSubmissionEmailController SubmissionsPreviewController SubmissionsPreviewDownloadController
      SubmittersDownloadController SubmissionsDownloadController
      Api::ActiveStorageBlobsProxyController Api::ActiveStorageBlobsProxyLegacyController
      Api::SubmitterFormViewsController Api::SubmitterEmailClicksController
    ].freeze
    ADMIN_PATTERN = /Submission|Submitter|Template/
    SKIP_METHODS = %w[GET HEAD OPTIONS].freeze
    RAW_MAIL_ACTIONS = {
      'SubmitterMailer' => %w[invitation_email invitation_view_email documents_copy_email]
    }.freeze
    SUBMIT_FORM_KINDS = { 'completed' => 'completed_page', 'delegated' => 'delegated_page' }.freeze
    SLUG_PATH_RE = %r{/(s|e|d|p|file|blobs_proxy|submitters)/[^/?]+}
    MAX_HEADER = 512
    PAYMENT_WORDING_RE = /zahlungspflichtig|kostenpflichtig|provisionspflichtig|kaufen|bezahlen/i
    TOKEN_PURPOSE = 'okorn_button_evidence'
    TOKEN_TTL = 12 * 3600
    CLICK_WINDOW_AFTER_COMPLETION = 15 * 60
    CLIENT_SCALARS = %w[event_type is_trusted text rendered kind button_id disabled visible covered form_language].freeze
    CLIENT_STYLE = %w[font_size font_weight color background text_transform opacity display visibility].freeze

    module_function

    def install!
      ActiveSupport::Notifications.subscribe('process_action.action_controller') do |event|
        safely { on_request(event.payload) }
      end
      ActiveSupport::Notifications.subscribe('process.action_mailer') do |event|
        safely { remember_mail_context(event.payload) }
      end
      ActionMailer::Base.register_interceptor(MailInterceptor)
      ActionMailer::Base.register_observer(MailObserver)
      @installed = true
    end

    def installed?
      @installed == true
    end

    def safely
      yield
    rescue StandardError => e
      OkornEvidence.report_error(e)
      nil
    end

    # ------------------------------------------------- ausgelieferte Seite

    # Aufruf aus submit_form/show.html.erb: Was die View tatsächlich in die
    # Seite schreibt, landet im Request und von dort im Protokoll; dazu ein
    # signiertes Token, das den späteren Klick-Nachweis an diese Auslieferung bindet.
    def served_button(request, submitter, result)
      render_id = SecureRandom.uuid
      served = if result
                 result.to_evidence.merge('forced_locale' => 'de', 'header_complete_button' => 'hidden',
                                          'label_has_payment_wording' => result.label.match?(PAYMENT_WORDING_RE))
               end
      request.env['okorn.served_button'] = { 'render_id' => render_id, 'button' => served }
      verifier.generate({ 's' => submitter.id, 'r' => render_id, 'l' => result&.label }, expires_in: TOKEN_TTL)
    rescue StandardError => e
      OkornEvidence.report_error(e)
      nil
    end

    def verifier
      Rails.application.message_verifier(TOKEN_PURPOSE)
    end

    # ---------------------------------------------------------------- HTTP

    def relevant?(controller, method)
      return false if controller.empty? || controller == 'OkornButtonEvidenceController'
      return true if SIGNER_CONTROLLERS.include?(controller)

      !SKIP_METHODS.include?(method.to_s) && controller.match?(ADMIN_PATTERN)
    end

    def on_request(payload)
      controller = payload[:controller].to_s
      return unless relevant?(controller, payload[:method])

      status = (payload[:status] || (payload[:exception] ? 500 : 0)).to_i
      return if [400, 404].include?(status)

      request = payload[:request]
      action = payload[:action].to_s
      path_params = request.respond_to?(:path_parameters) ? request.path_parameters.stringify_keys : {}
      params = request.respond_to?(:parameters) ? request.parameters : {}

      data = {
        'controller' => controller, 'action' => action, 'method' => payload[:method], 'status' => status,
        'path' => mask_path(payload[:path]), 'request_id' => request&.request_id,
        'exception' => payload[:exception]&.first
      }
      kind = describe(controller, action, status, path_params, params, data, request)
      return unless kind

      unless kind == 'step_saved'
        data['ip'] = request&.remote_ip
        data['user_agent'] = OkornEvidence.truncate(request&.user_agent.to_s, MAX_HEADER)
      end
      data['user_id'] = current_user_id(request) unless SIGNER_CONTROLLERS.include?(controller)

      OkornEvidence.record("http.#{kind}", data)
    end

    # Liefert die Ereignisart oder nil, wenn nichts protokolliert werden soll
    # (Ressource nicht gefunden).
    def describe(controller, action, status, path_params, params, data, request)
      case controller
      when 'SubmitFormController'
        submitter = find_submitter(path_params['slug'] || path_params['submit_form_slug'])
        return unless submitter

        data['submitter'] = submitter_info(submitter)
        case action
        when 'show' then signing_page(data, request)
        when 'update' then form_update(data, params, status, submitter)
        else SUBMIT_FORM_KINDS[action] || action
        end
      when 'SubmitFormInviteController'
        submitter = find_submitter(path_params['submit_form_slug'])
        return unless submitter

        data['submitter'] = submitter_info(submitter)
        submitter.reload.completed_at && status == 200 ? completed(data, submitter) : 'invite'
      when 'SubmitFormCompletedDownloadController', 'SubmitFormDownloadController'
        submitter = find_submitter(path_params['submit_form_slug'] || path_params['submitter_slug'] || params['submitter_slug'])
        return unless submitter

        data['submitter'] = submitter_info(submitter)
        'download_links'
      when 'Api::ActiveStorageBlobsProxyController', 'Api::ActiveStorageBlobsProxyLegacyController'
        return unless [200, 206].include?(status)

        data['file'] = blob_info(path_params['signed_uuid'])
        'file_download'
      when 'SubmissionsPreviewController', 'SubmissionsPreviewDownloadController'
        submission = ::Submission.find_by(slug: (path_params['slug'] || path_params['submissions_preview_slug']).to_s)
        return unless submission

        data['submission'] = submission_ref(submission)
        action == 'index' ? 'preview_download' : 'preview_page'
      when 'StartFormResubmitController'
        submitter = find_submitter(params['resubmit'])
        return unless submitter

        data['submitter'] = submitter_info(submitter)
        'resubmit'
      when 'SendSubmissionEmailController'
        submitter = find_submitter(params['submitter_slug'])
        data['submitter'] = submitter_info(submitter) if submitter
        submission = ::Submission.find_by(slug: params['submission_slug'].to_s) if params['submission_slug'].present?
        data['submission'] = submission_ref(submission) if submission
        return unless submitter || submission

        'copy_email_requested'
      when 'StartFormController', 'StartFormSelfController'
        template = ::Template.find_by(slug: (path_params['slug'] || params['slug']).to_s)
        return unless template

        data['template_id'] = template.id
        "start_form_#{action}"
      when /\AApi::Submitter(FormViews|EmailClicks)Controller\z/
        data['submitter'] = submitter_info(find_submitter(params['submitter_slug']) || find_submitter_by_id(params['submitter_id']))
        Regexp.last_match(1) == 'FormViews' ? 'form_viewed' : 'email_click'
      when /\ASubmitForm/
        submitter = find_submitter(path_params['submit_form_slug'])
        return unless submitter

        data['submitter'] = submitter_info(submitter)
        controller.delete_prefix('SubmitForm').delete_suffix('Controller').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      else
        admin_refs(controller, path_params, params, data)
        "admin_#{controller.delete_suffix('Controller').gsub('::', '_').downcase}_#{action}"
      end
    end

    def signing_page(data, request)
      served = request&.env&.[]('okorn.served_button')
      return 'signing_page_other' unless served

      data['render_id'] = served['render_id']
      data['button'] = served['button'] || { 'label' => nil, 'note' => 'kein Auslöser: DocuSeal-Standardbeschriftung' }
      'signing_page'
    end

    def form_update(data, params, status, submitter)
      return 'step_saved' unless params['completed'].to_s == 'true'
      return completed(data, submitter) if status == 200

      'form_complete_rejected'
    end

    def completed(data, submitter)
      result = OkornButtonLabel.compute(submitter)
      data['button'] = result ? result.to_evidence : { 'label' => nil }
      'form_completed'
    end

    def admin_refs(controller, path_params, params, data)
      id = path_params['id']
      if controller.match?(/Submitter/)
        submitter = find_submitter_by_id(path_params['submitter_id'] || id) || find_submitter(params['submitter_slug'])
        data['submitter'] = submitter_info(submitter) if submitter
      end
      if controller.match?(/Submission/)
        submission = ::Submission.find_by(id: (path_params['submission_id'] || id).to_i) if (path_params['submission_id'] || id).to_s.match?(/\A\d+\z/)
        data['submission'] = submission_ref(submission) if submission
      end
      data['params_id'] = id if id
    end

    def mask_path(path)
      OkornEvidence.truncate(path.to_s.split('?').first.to_s.gsub(SLUG_PATH_RE, '/\1/:slug'), MAX_HEADER)
    end

    def find_submitter(slug)
      return if slug.to_s.empty?

      ::Submitter.find_by(slug: slug.to_s)
    end

    def find_submitter_by_id(id)
      return unless id.to_s.match?(/\A\d+\z/)

      ::Submitter.find_by(id: id.to_i)
    end

    def submitter_info(submitter)
      return unless submitter

      {
        'id' => submitter.id, 'slug_sha256' => OkornEvidence.slug_digest(submitter.slug), 'role_uuid' => submitter.uuid,
        'submission_id' => submitter.submission_id, 'completed_at' => submitter.completed_at,
        'declined_at' => submitter.try(:declined_at)
      }
    end

    def submission_ref(submission)
      { 'submission_id' => submission.id, 'slug_sha256' => OkornEvidence.slug_digest(submission.slug) }
    end

    def blob_info(signed_uuid)
      blob_uuid, purpose, = ::ApplicationRecord.signed_id_verifier.verified(signed_uuid.to_s)
      return { 'note' => 'Signatur ungültig' } if blob_uuid.blank? || purpose != 'blob'

      blob = ::ActiveStorage::Blob.find_by(uuid: blob_uuid)
      return { 'blob_uuid' => blob_uuid, 'note' => 'nicht gefunden' } unless blob

      {
        'blob_uuid' => blob_uuid, 'filename' => blob.filename.to_s, 'bytes' => blob.byte_size,
        'checksum_md5_b64' => blob.checksum,
        # Format wie im DocuSeal-Prüfprotokoll (Base64url des SHA-256)
        'sha256_b64url' => blob.metadata.is_a?(Hash) ? blob.metadata['sha256'] : nil,
        'attached_to' => blob.attachments.map { |a| attachment_owner(a) }
      }
    end

    def attachment_owner(attachment)
      owner = { 'type' => attachment.record_type, 'id' => attachment.record_id, 'name' => attachment.name }
      record = attachment.record
      owner['submission_id'] = record.submission_id if record.respond_to?(:submission_id)
      owner['submission_id'] = record.id if attachment.record_type == 'Submission'
      owner
    rescue StandardError
      owner
    end

    def current_user_id(request)
      request&.env&.dig('warden')&.user(:user)&.id
    rescue StandardError
      nil
    end

    # ----------------------------------------------------- Klick-Nachweis

    # Prüft das Token aus der ausgelieferten Seite. Liefert nil, wenn der
    # Nachweis nicht angenommen werden soll.
    def verified_click(payload)
      token = verifier.verified(payload['token'].to_s)
      return unless token.is_a?(Hash)

      submitter = ::Submitter.find_by(id: token['s'])
      return unless submitter
      return if submitter.try(:declined_at)
      return if submitter.completed_at && submitter.completed_at < Time.current - CLICK_WINDOW_AFTER_COMPLETION

      [submitter, token]
    end

    def attestation(submitter, token, payload, request)
      label = token['l']
      client = payload.slice(*CLIENT_SCALARS).transform_values { |value| value.is_a?(String) ? OkornEvidence.truncate(value, 200) : value }
      client.select! { |_, value| [String, TrueClass, FalseClass, NilClass, Integer, Float].any? { |klass| value.is_a?(klass) } }
      style = payload['style'].is_a?(Hash) ? payload['style'].slice(*CLIENT_STYLE) : {}
      client['style'] = style.transform_values { |value| OkornEvidence.truncate(value.to_s, 64) }
      rect = payload['rect'].is_a?(Hash) ? payload['rect'].slice('w', 'h') : {}
      client['size'] = rect.transform_values(&:to_i)

      text = client['text'].to_s
      rendered = client['rendered'].to_s.gsub(/\s+/, ' ').strip

      {
        'submitter' => submitter_info(submitter),
        'render_id' => token['r'],
        'label_served' => label,
        'client' => client,
        'check' => {
          'text_matches_label' => label ? text == label : nil,
          'rendered_matches_label' => label ? rendered.casecmp?(label) : nil,
          'visible' => client['visible'], 'covered' => client['covered'], 'is_trusted' => client['is_trusted']
        },
        'ip' => request.remote_ip,
        'user_agent' => OkornEvidence.truncate(request.user_agent.to_s, MAX_HEADER),
        'request_id' => request.request_id
      }
    end

    # ----------------------------------------------------------- E-Mail

    def remember_mail_context(payload)
      args = Array(payload[:args])
      submitter = args.find { |arg| defined?(::Submitter) && arg.is_a?(::Submitter) }

      Thread.current[:okorn_mail_ctx] = {
        'mailer' => payload[:mailer].to_s, 'action' => payload[:action].to_s,
        'submitter' => submitter_info(submitter)
      }
    end

    def mail_context
      Thread.current[:okorn_mail_ctx] || {}
    end

    def raw_allowed?(mailer, action)
      Array(RAW_MAIL_ACTIONS[mailer.to_s]).include?(action.to_s)
    end

    def delivery_info(message)
      delivery = message.delivery_method
      settings = delivery.respond_to?(:settings) ? (delivery.settings || {}) : {}
      method = case delivery.class.name
               when /SMTP/ then 'smtp'
               when /TestMailer/ then 'test'
               when /Sendmail/ then 'sendmail'
               when /FileDelivery/ then 'file'
               else delivery.class.name
               end

      { 'method' => method, 'smtp_address' => settings[:address], 'smtp_port' => settings[:port] }
    end

    def mail_headers(message)
      {
        'to' => Array(message.to), 'cc' => Array(message.cc), 'bcc' => Array(message.bcc),
        'from' => Array(message.from), 'reply_to' => Array(message.reply_to), 'subject' => message.subject,
        'message_id' => message.message_id, 'date' => message.date&.iso8601
      }
    end

    module MailInterceptor
      module_function

      # Läuft vor der Zustellung (auch bei deliver!). Fehlt danach der passende
      # "mail"-Eintrag, ist die Übergabe an den Mailserver gescheitert.
      # Die Nachricht selbst wird nicht verändert; die Zuordnung zum späteren
      # "mail"-Eintrag läuft über die Sequenznummer im selben Thread.
      def delivering_email(message)
        RailsHooks.safely do
          entry = OkornEvidence.record('mail_attempt', RailsHooks.mail_context.merge(RailsHooks.mail_headers(message)))
          Thread.current[:okorn_mail_attempt] = entry && entry['seq']
        end
      end
    end

    module MailObserver
      module_function

      def delivered_email(message)
        RailsHooks.safely { RailsHooks.record_mail(message) }
      end
    end

    def record_mail(message)
      ctx = mail_context
      Thread.current[:okorn_mail_ctx] = nil

      delivery = delivery_info(message)
      delivery['accepted_by_smtp_relay'] = delivery['method'] == 'smtp'
      delivery['note'] = 'Testzustellung: nicht versendet (kein SMTP konfiguriert)' if delivery['method'] == 'test'

      attempt_seq = Thread.current[:okorn_mail_attempt]
      Thread.current[:okorn_mail_attempt] = nil

      data = ctx.merge(mail_headers(message)).merge(
        'attempt_seq' => attempt_seq,
        'delivery' => delivery,
        'attachments' => message.attachments.map do |part|
          body = part.body.decoded
          digest = Digest::SHA256.digest(body)
          { 'filename' => part.filename, 'mime' => part.mime_type, 'bytes' => body.bytesize,
            'sha256_hex' => digest.unpack1('H*'), 'sha256_b64url' => Base64.urlsafe_encode64(digest) }
        end
      )
      data['raw'] = OkornEvidence.store_raw('mail', message.encoded, extension: 'eml') if raw_allowed?(ctx['mailer'], ctx['action'])

      OkornEvidence.record('mail', data)
    end
  end
end
