# frozen_string_literal: true

# OKorn-Overlay: Anbindung des Beweisprotokolls an DocuSeal (Rails).
# Ausschließlich Beobachter (ActiveSupport::Notifications, Mail-Observer):
# kein Eingriff in Controller, Signaturlogik oder Mailversand.
#
# Protokolliert:
#   http.*      Unterzeichner-Seiten, Formularschritte, Abschluss, Downloads
#               (mit Datei-Prüfsumme), erneutes Einreichen, Kopie-Mail-Anforderung,
#               Ablehnen, Admin-Änderungen an Vorgängen und Unterzeichnern
#   mail        jede ausgehende Mail: Empfänger, Message-ID, Zustellweg,
#               Anhänge mit SHA-256; für Unterzeichner-Mails zusätzlich die
#               vollständige .eml als Archivkopie (keine Einmalcodes)
#   mail_failed Zustellfehler beim Übergeben an den Mailserver
#   button_click Klick-Nachweis aus dem Browser (OkornButtonEvidenceController)

require 'digest'

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
    ].freeze
    ADMIN_PATTERN = /Submission|Submitter|Template/
    SKIP_METHODS = %w[GET HEAD OPTIONS].freeze
    RAW_MAIL_ACTIONS = {
      'SubmitterMailer' => %w[invitation_email invitation_view_email completed_email declined_email documents_copy_email]
    }.freeze
    CLIENT_KEYS = %w[v event_type is_trusted label_expected text rendered kind button_id disabled visible covered
                     top_element rect viewport dpr style form_language lang client_ts path orientation].freeze
    SUBMIT_FORM_KINDS = { 'show' => 'signing_page', 'completed' => 'completed_page', 'delegated' => 'delegated_page' }.freeze

    module_function

    def install!
      ActiveSupport::Notifications.subscribe('process_action.action_controller') do |event|
        safely { on_request(event.payload) }
      end
      ActiveSupport::Notifications.subscribe('process.action_mailer') do |event|
        safely { remember_mail_context(event.payload) }
      end
      ActiveSupport::Notifications.subscribe('deliver.action_mailer') do |event|
        safely { on_deliver_finished(event.payload) }
      end
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

    # ---------------------------------------------------------------- HTTP

    def relevant?(controller, method)
      return false if controller.empty? || controller == 'OkornButtonEvidenceController'
      return true if SIGNER_CONTROLLERS.include?(controller)

      !SKIP_METHODS.include?(method.to_s) && controller.match?(ADMIN_PATTERN)
    end

    def on_request(payload)
      controller = payload[:controller].to_s
      return unless relevant?(controller, payload[:method])

      request = payload[:request]
      action = payload[:action].to_s
      status = payload[:status] || (payload[:exception] ? 500 : nil)
      path_params = request.respond_to?(:path_parameters) ? request.path_parameters.stringify_keys : {}
      params = request.respond_to?(:parameters) ? request.parameters : {}

      data = {
        'controller' => controller, 'action' => action, 'method' => payload[:method], 'status' => status,
        'path' => payload[:path].to_s.split('?').first, 'ip' => request&.remote_ip,
        'forwarded_for' => request&.headers&.[]('X-Forwarded-For'), 'user_agent' => request&.user_agent,
        'request_id' => request&.request_id, 'exception' => payload[:exception]&.first
      }
      data['user_id'] = current_user_id(request) unless SIGNER_CONTROLLERS.include?(controller)

      kind = describe(controller, action, status, path_params, params, data)
      OkornEvidence.record("http.#{kind}", data)
    end

    def describe(controller, action, status, path_params, params, data)
      case controller
      when 'SubmitFormController'
        submitter = find_submitter(path_params['slug'])
        data['submitter'] = submitter_info(submitter)
        kind = SUBMIT_FORM_KINDS[action] || (params['completed'].to_s == 'true' ? 'form_completed' : 'step_saved')
        data['button'] = button_info(submitter) if submitter && status.to_i == 200 && %w[signing_page form_completed].include?(kind)
        kind
      when 'SubmitFormCompletedDownloadController', 'SubmitFormDownloadController'
        data['submitter'] = submitter_info(find_submitter(path_params['submit_form_slug'] || path_params['submitter_slug']))
        'download_links'
      when 'Api::ActiveStorageBlobsProxyController', 'Api::ActiveStorageBlobsProxyLegacyController'
        data['file'] = blob_info(path_params['signed_uuid']) if status.to_i == 200
        'file_download'
      when 'SubmissionsPreviewController', 'SubmissionsPreviewDownloadController'
        data['submission'] = submission_info(path_params['slug'] || path_params['submissions_preview_slug'])
        action == 'index' ? 'preview_download' : 'preview_page'
      when 'StartFormResubmitController'
        data['submitter'] = submitter_info(find_submitter(params['resubmit']))
        'resubmit'
      when 'SendSubmissionEmailController'
        data['submitter'] = submitter_info(find_submitter(params['submitter_slug']))
        'copy_email_requested'
      when 'StartFormController', 'StartFormSelfController'
        data['template_slug'] = path_params['slug'] || params['slug']
        "start_form_#{action}"
      when /\ASubmitForm/
        data['submitter'] = submitter_info(find_submitter(path_params['submit_form_slug']))
        controller.delete_prefix('SubmitForm').delete_suffix('Controller').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      else
        data['params_id'] = path_params['id']
        "admin_#{controller.delete_suffix('Controller').gsub('::', '_').downcase}_#{action}"
      end
    end

    def button_info(submitter)
      result = OkornButtonLabel.compute(submitter)
      return { 'label' => nil, 'note' => 'kein Auslöser: DocuSeal-Standardbeschriftung' } unless result

      result.to_evidence.merge('forced_locale' => 'de', 'header_complete_button' => 'hidden')
    end

    def find_submitter(slug)
      return if slug.to_s.empty?

      ::Submitter.find_by(slug: slug.to_s)
    end

    def submitter_info(submitter)
      return unless submitter

      {
        'id' => submitter.id, 'slug' => submitter.slug, 'role_uuid' => submitter.uuid,
        'submission_id' => submitter.submission_id, 'completed_at' => submitter.completed_at,
        'declined_at' => submitter.try(:declined_at)
      }
    end

    def submission_info(slug)
      return if slug.to_s.empty?

      submission = ::Submission.find_by(slug: slug.to_s)
      submission && { 'submission_id' => submission.id, 'slug' => submission.slug }
    end

    def blob_info(signed_uuid)
      blob_uuid, purpose, = ::ApplicationRecord.signed_id_verifier.verified(signed_uuid.to_s)
      return { 'note' => 'Signatur ungültig' } if blob_uuid.blank? || purpose != 'blob'

      blob = ::ActiveStorage::Blob.find_by(uuid: blob_uuid)
      return { 'blob_uuid' => blob_uuid, 'note' => 'nicht gefunden' } unless blob

      {
        'blob_uuid' => blob_uuid, 'filename' => blob.filename.to_s, 'bytes' => blob.byte_size,
        'checksum_md5' => blob.checksum, 'sha256' => blob.metadata.is_a?(Hash) ? blob.metadata['sha256'] : nil,
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

    def attestation(submitter, payload, request)
      expected = OkornButtonLabel.compute(submitter)
      label = expected&.label
      text = payload['text'].to_s
      rendered = payload['rendered'].to_s.gsub(/\s+/, ' ').strip

      {
        'submitter' => submitter_info(submitter),
        'expected' => expected&.to_evidence,
        'client' => OkornEvidence.sanitize(payload.slice(*CLIENT_KEYS)),
        'check' => {
          'text_matches_label' => label ? text == label : nil,
          'rendered_matches_label' => label ? rendered.casecmp?(label) : nil,
          'visible' => payload['visible'], 'covered' => payload['covered'], 'is_trusted' => payload['is_trusted']
        },
        'ip' => request.remote_ip, 'forwarded_for' => request.headers['X-Forwarded-For'],
        'user_agent' => request.user_agent, 'request_id' => request.request_id
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

    def take_mail_context
      Thread.current[:okorn_mail_ctx].tap { Thread.current[:okorn_mail_ctx] = nil } || {}
    end

    def on_deliver_finished(payload)
      return unless payload[:exception]

      ctx = take_mail_context
      OkornEvidence.record('mail_failed', ctx.merge(
        'to' => Array(payload[:to]), 'subject' => payload[:subject], 'message_id' => payload[:message_id],
        'error' => Array(payload[:exception]).join(': ')
      ))
    end

    def raw_allowed?(mailer, action)
      Array(RAW_MAIL_ACTIONS[mailer.to_s]).include?(action.to_s)
    end

    module MailObserver
      module_function

      def delivered_email(message)
        RailsHooks.safely { RailsHooks.record_mail(message) }
      end
    end

    def record_mail(message)
      ctx = take_mail_context
      delivery = message.delivery_method
      settings = delivery.respond_to?(:settings) ? (delivery.settings || {}) : {}
      method = case delivery.class.name
               when /SMTP/ then 'smtp'
               when /TestMailer/ then 'test'
               when /Sendmail/ then 'sendmail'
               when /FileDelivery/ then 'file'
               else delivery.class.name
               end

      data = ctx.merge(
        'to' => Array(message.to), 'cc' => Array(message.cc), 'bcc' => Array(message.bcc),
        'from' => Array(message.from), 'reply_to' => Array(message.reply_to), 'subject' => message.subject,
        'message_id' => message.message_id, 'date' => message.date&.iso8601,
        'delivery' => { 'method' => method, 'actually_sent' => method != 'test',
                        'smtp_address' => settings[:address], 'smtp_port' => settings[:port] },
        'attachments' => message.attachments.map do |part|
          body = part.body.decoded
          { 'filename' => part.filename, 'mime' => part.mime_type, 'bytes' => body.bytesize,
            'sha256' => Digest::SHA256.hexdigest(body) }
        end
      )
      data['raw'] = OkornEvidence.store_raw('mail', message.encoded, extension: 'eml') if raw_allowed?(ctx['mailer'], ctx['action'])

      OkornEvidence.record('mail', data)
    end
  end
end
