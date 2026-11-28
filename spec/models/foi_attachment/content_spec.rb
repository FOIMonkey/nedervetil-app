require 'spec_helper'

RSpec.describe FoiAttachment::Content do
  it 'treats a missing filename as having no image extension' do
    expect(described_class.image_filename?(nil)).to be false
  end

  it 'keeps the field order used by stored suggestion fingerprints' do
    part = FactoryBot.create(:foi_attachment)
    expect(described_class.fingerprint(part)).
      to eq([part.updated_at.to_f, part.masked_at.to_f, nil, nil,
             part.hexdigest, part.prominence, part.file_blob.id,
             part.file_blob.checksum])
  end

  it 'masks a part’s document text too' do
    part = FactoryBot.create(:body_text, body: 'Write to jane@example.org.')
    expect(described_class.document_text(part)).
      not_to include('jane@example.org')
  end

  it 'logs which error left a part’s document text unread, by its class' do
    part = FactoryBot.create(:body_text, body: 'Write to jane@example.org.')
    allow(part).to receive(:body_to_text).
      and_raise(NoMethodError, 'jane@example.org')
    allow(Rails.logger).to receive(:warn).and_call_original
    expect(described_class.document_text(part)).to be_nil
    expect(Rails.logger).to have_received(:warn).
      with("request_outcome_document_text_failed attachment_id=#{part.id} " \
           'NoMethodError')
  end
end
