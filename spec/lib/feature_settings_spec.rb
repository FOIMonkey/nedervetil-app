require 'spec_helper'

RSpec.describe 'Feature settings in general.yml' do
  it 'keeps the defaults the environment variables had' do
    expect(AlaveteliConfiguration::DEFAULTS).to include(
      ATTACHMENT_MANAGEMENT_REQUESTER_ACCESS: 'redact',
      ATTACHMENT_MANAGEMENT_DRAFT_HOURS: 4,
      ATTACHMENT_MANAGEMENT_PREVIEW_HOURS: 4,
      DISCLOSURES_REQUESTER_EDITING: true,
      DISCLOSURES_REVIEW_REQUESTER_REDACTIONS: true,
      DISCLOSURES_OCR: true,
      DISCLOSURES_REMOVE_OFFICE_METADATA: false,
      INCOMING_ATTENTION_ENABLED: false,
      INCOMING_ATTENTION_ENDPOINT: '',
      INCOMING_ATTENTION_BACKFILL_RECEIVED_AFTER: '',
      INCOMING_OUTCOME_MODE: 'off',
      INCOMING_OUTCOME_STRICT_DOCUMENTS: false,
      INCOMING_OUTCOME_OCR: false
    )
  end

  it 'gives the features those defaults' do
    expect(AttachmentManagement.requester_access).to eq('redact')
    expect(AttachmentManagement.draft_retention).to eq(4.hours)
    expect(AttachmentManagement.preview_retention).to eq(4.hours)
    expect(Disclosures.requester_editing?).to be true
    expect(Disclosures.review_requester_redactions?).to be true
    expect(Disclosures::Tidy.on?).to be false
    expect(IncomingAttention::Outcome.mode).to eq('off')
    expect(IncomingAttention::Outcome.strict_documents?).to be false
    expect(IncomingAttention::Outcome::Ocr.enabled?).to be false
  end

  it 'documents each of them in general.yml-example with the same value' do
    example = YAML.load_file(Rails.root.join('config/general.yml-example'))
    keys = %i[ATTACHMENT_MANAGEMENT_REQUESTER_ACCESS
              ATTACHMENT_MANAGEMENT_DRAFT_HOURS
              ATTACHMENT_MANAGEMENT_PREVIEW_HOURS
              DISCLOSURES_REQUESTER_EDITING
              DISCLOSURES_REVIEW_REQUESTER_REDACTIONS
              DISCLOSURES_OCR
              DISCLOSURES_REMOVE_OFFICE_METADATA
              INCOMING_ATTENTION_ENABLED
              INCOMING_ATTENTION_ENDPOINT
              INCOMING_ATTENTION_BACKFILL_RECEIVED_AFTER
              INCOMING_OUTCOME_MODE
              INCOMING_OUTCOME_STRICT_DOCUMENTS
              INCOMING_OUTCOME_OCR]
    keys.each do |key|
      expect(example.fetch(key.to_s)).
        to eq(AlaveteliConfiguration::DEFAULTS.fetch(key))
    end
  end
end
