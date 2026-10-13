# frozen_string_literal: true

# OKorn-Overlay (github.com/nextamed/docuseal-branding): Buttonlösung und
# Beweisprotokoll. Details: config/okorn/*.rb und README "Beweisprotokoll".
# Der `zz_`-Prefix lädt diese Datei nach den DocuSeal-Initializern.

require_relative '../okorn/button_label'
require_relative '../okorn/evidence'
require_relative '../okorn/evidence_shipper'
require_relative '../okorn/evidence_rails'

Rails.application.routes.prepend do
  post '/okorn/button_evidence', to: 'okorn_button_evidence#create', as: :okorn_button_evidence
end

begin
  OkornEvidence::RailsHooks.install! if OkornEvidence.enabled?
rescue StandardError => e
  # Das Beweisprotokoll darf DocuSeal nie am Starten hindern.
  OkornEvidence.report_error(e)
end
