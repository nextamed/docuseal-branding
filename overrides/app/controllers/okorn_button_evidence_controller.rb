# frozen_string_literal: true

# OKorn-Overlay (github.com/nextamed/docuseal-branding): nimmt den Klick-Nachweis
# der Abschluss-Schaltfläche entgegen (navigator.sendBeacon aus
# submit_form/show.html.erb) und schreibt ihn ins Beweisprotokoll.
# Reiner Beobachter: beeinflusst den Signaturablauf nicht.
class OkornButtonEvidenceController < ActionController::API
  MAX_BYTES = 16_384
  SLUG_RE = /\A[A-Za-z0-9_-]{4,64}\z/

  def create
    body = request.raw_post.to_s
    return head(413) if body.bytesize > MAX_BYTES

    payload = JSON.parse(body)
    return head(:bad_request) unless payload.is_a?(Hash) && payload['slug'].to_s.match?(SLUG_RE)

    submitter = Submitter.find_by(slug: payload['slug'])
    return head(:not_found) unless submitter

    OkornEvidence.record('button_click', OkornEvidence::RailsHooks.attestation(submitter, payload, request))

    head :no_content
  rescue JSON::ParserError
    head :bad_request
  end
end
