# frozen_string_literal: true

# OKorn-Overlay (github.com/nextamed/docuseal-branding): nimmt den Klick-Nachweis
# der Abschluss-Schaltfläche entgegen (navigator.sendBeacon aus
# submit_form/show.html.erb) und schreibt ihn ins Beweisprotokoll.
# Reiner Beobachter: beeinflusst den Signaturablauf nicht und antwortet immer
# schnell. Angenommen wird nur, was ein signiertes Token aus einer
# ausgelieferten Signaturseite trägt, gedrosselt pro Auslieferung und Adresse.
class OkornButtonEvidenceController < ActionController::API
  MAX_BYTES = 8_192
  PER_RENDER_LIMIT = 10
  PER_IP_LIMIT = 60

  def create
    body = request.raw_post.to_s
    return head(413) if body.bytesize > MAX_BYTES

    payload = JSON.parse(body)
    return head(:bad_request) unless payload.is_a?(Hash)

    RateLimit.call("okorn-beacon-ip-#{request.remote_ip}", limit: PER_IP_LIMIT, ttl: 1.minute, enabled: true)
    submitter, token = OkornEvidence::RailsHooks.verified_click(payload)
    return head(:no_content) unless submitter

    RateLimit.call("okorn-beacon-render-#{token['r']}", limit: PER_RENDER_LIMIT, ttl: 1.hour, enabled: true)
    OkornEvidence.record('button_click', OkornEvidence::RailsHooks.attestation(submitter, token, payload, request))

    head :no_content
  rescue JSON::ParserError
    head :bad_request
  rescue RateLimit::LimitApproached
    head :no_content
  end
end
