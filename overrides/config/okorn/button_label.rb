# frozen_string_literal: true

# OKorn-Overlay (github.com/nextamed/docuseal-branding): Beschriftung der
# Abschluss-Schaltfläche nach § 312j Abs. 3 BGB. Einzige Quelle für die View
# (submit_form/show.html.erb) und das Beweisprotokoll, damit ausgelieferte
# und protokollierte Beschriftung nicht auseinanderlaufen können.
#
# Auslöser pro Unterzeichner (Rolle), in dieser Reihenfolge:
#   1. Marker ##button: Text## oder ##button->Text## in Name, Titel oder
#      Beschreibung eines Feldes der Rolle -> genau dieser Text
#   2. Submitter-Metadaten payment_notice (ok_manage) -> Standardtext
#   3. "zahlungspflichtig" in Name oder Titel eines Feldes der Rolle -> Standardtext
module OkornButtonLabel
  DEFAULT_LABEL = 'Zahlungspflichtig / provisionspflichtig abschließen'
  MARKER_RE = /##\s*button\s*(?:->|:)\s*([^#]+?)\s*##/i
  KEYWORD_RE = /zahlungspflichtig/i

  Result = Struct.new(:label, :trigger, :field_uuid, keyword_init: true) do
    def to_evidence
      { 'label' => label, 'trigger' => trigger, 'field_uuid' => field_uuid }.compact
    end
  end

  module_function

  def compute(submitter)
    fields = submitter_fields(submitter)

    fields.each do |field|
      marker = [field['name'], field['title'], field['description']].compact.join(' ')[MARKER_RE, 1]

      return Result.new(label: marker, trigger: 'marker', field_uuid: field['uuid']) if present?(marker)
    end

    metadata = submitter.metadata.is_a?(Hash) ? submitter.metadata : {}
    keyword_field = fields.find { |field| "#{field['name']} #{field['title']}".match?(KEYWORD_RE) }
    triggers = []
    triggers << 'metadata' if present?(metadata['payment_notice'])
    triggers << 'keyword' if keyword_field

    return if triggers.empty?

    Result.new(label: DEFAULT_LABEL, trigger: triggers.join('+'), field_uuid: keyword_field&.dig('uuid'))
  end

  def submitter_fields(submitter)
    submission = submitter.submission
    fields = submission.template_fields || submission.template&.fields

    Array(fields).select { |field| field.is_a?(Hash) && field['submitter_uuid'] == submitter.uuid }
  end

  # Entspricht ActiveSupport#present? für die hier vorkommenden Werte.
  def present?(value)
    return false if value.nil? || value == false
    return !value.strip.empty? if value.is_a?(String)
    return !value.empty? if value.respond_to?(:empty?)

    true
  end
end
