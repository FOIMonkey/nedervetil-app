require 'spec_helper'
RSpec.describe IncomingAttention::Input do
  let(:metadata) {
    { 'attachment_filenames_available' => true,
      'non_image_attachment_filenames' => ['résumé.pdf'],
      'image_attachments_ignored' => 1 }
  }
  it 'cuts the reply at whole UTF-8 characters so it, the framing and the filenames fit the state' do
    body, shortened = described_class.prepare('🧾é' * 4000, metadata)
    expect(body.bytesize + described_class::FRAME_BYTES + JSON.generate(
      metadata
    ).bytesize).to be <= described_class::STATE_BYTES
    expect(body).to be_valid_encoding
    expect(shortened).to be true
  end
  it 'leaves small replies intact' do
    expect(described_class.prepare('We received your request.', metadata)).
      to eq(['We received your request.', false])
  end
  it 'refuses metadata that leaves no room for the reply, and an empty reply, before anything is sent' do
    metadata['non_image_attachment_filenames'] = ['a' * 8192]
    expect { described_class.prepare('Reply', metadata) }.
      to raise_error(described_class::Unavailable, 'input_limit')
    expect { described_class.prepare(" \n", {}) }.
      to raise_error(described_class::Unavailable, 'body_empty')
  end
end
