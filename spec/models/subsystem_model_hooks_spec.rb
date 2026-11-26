require 'spec_helper'

RSpec.describe 'Fork model hooks' do
  # Non-transactional after callbacks are stored in reverse execution order.
  # Keep fork hooks after core work, including association saves.
  {
    InfoRequest => {
      create: { after: %i[autosave_associated_records_for_deadline_adjustments
                          autosave_associated_records_for_deadline_closures
                          request_limits_record] },
      update: { after: %i[invalidate_attention_predictions
                          autosave_associated_records_for_deadline_adjustments
                          autosave_associated_records_for_deadline_closures] },
      destroy: { before: %i[expire] }
    },
    IncomingMessage => {
      create: { after: %i[autosave_associated_records_for_foi_attachments
                          create_attention_prediction
                          store_text_later] },
      update: { after: %i[update_request invalidate_attention_prediction] }
    },
    FoiAttachment => {
      update: { after: %i[invalidate_attention_prediction] }
    },
    OutgoingMessage => {
      create: { after: %i[autosave_associated_records_for_info_request_events
                          request_limits_record] }
    },
    User => {
      create: { after: %i[autosave_associated_records_for_roles] }
    }
  }.each do |model, chains|
    chains.each do |chain, kinds|
      kinds.each do |kind, names|
        it "keeps #{model}'s #{kind}_#{chain} hook order without duplicates" do
          callbacks = model.public_send("_#{chain}_callbacks").
            select { |callback| callback.kind == kind }.map(&:filter)
          callbacks.reverse! if kind == :after
          expect(callbacks.select { |name| names.include?(name) }).to eq(names)
        end
      end
    end
  end

  # Queued by IncomingMessage::StoreTextJob instead.
  it 'queues no reading or suggestion from a hook of its own on the reply' do
    hooks = (IncomingMessage._commit_callbacks.to_a +
             IncomingMessage._create_callbacks.to_a).map(&:filter)
    expect(hooks).not_to include(:queue_attention_prediction,
                                 :suggest_documents_later,
                                 :queue_text_readers)
  end

  describe 'reparsing a reply' do
    let(:message) { FactoryBot.create(:incoming_message) }

    it 'checks spreadsheets after core has parsed the reply' do
      message.update_column(:last_parsed, nil)
      checked = false
      allow(Disclosures::SpreadsheetHold).to receive(:check_later).
        with(message) { checked = message.last_parsed.present? }

      expect(message.parse_raw_email!).to be true
      expect(message.reload.last_parsed).to be_present
      expect(checked).to be true
    end

    it 'forwards once to core while still checking spreadsheets' do
      message.parse_raw_email!
      expect(message).not_to receive(:extract_attachments)
      expect(Disclosures::SpreadsheetHold).to receive(:check_later).
        with(message)

      message.parse_raw_email!(once: true)
    end

    it 'checks spreadsheets when parsing raises and preserves the original error' do
      allow(message).to receive(:extract_attachments).and_raise('Parse stopped')
      expect(Disclosures::SpreadsheetHold).to receive(:check_later).
        with(message)

      expect { message.parse_raw_email! }.to raise_error('Parse stopped')
    end
  end
end
