require 'spec_helper'

RSpec.describe FoiAttachment::EraseJob, type: :job do
  let(:info_request) { FactoryBot.create(:info_request_with_incoming) }
  let(:incoming_message) { info_request.incoming_messages.first }
  let(:attachment) do
    FactoryBot.create(:body_text, incoming_message: incoming_message)
  end
  let(:editor) { FactoryBot.create(:admin_user) }
  let(:reason) { 'GDPR request' }

  def perform
    described_class.new.perform(attachment, editor: editor, reason: reason)
  end

  describe 'uniqueness' do
    before { described_class.unlock! }
    after { described_class.unlock! }

    it 'does not enqueue the same erasure twice' do
      expect {
        2.times do
          described_class.perform_later(attachment,
                                        editor: editor, reason: reason)
        end
      }.to have_enqueued_job(described_class).exactly(:once)
    end

    it 'enqueues erasures for distinct attachments' do
      sibling = FactoryBot.create(:body_text,
                                  incoming_message: incoming_message)
      expect {
        described_class.perform_later(attachment,
                                      editor: editor, reason: reason)
        described_class.perform_later(sibling, editor: editor, reason: reason)
      }.to have_enqueued_job(described_class).twice
    end
  end

  it 'erases the attachment' do
    expect(attachment).to receive(:erase).with(editor: editor, reason: reason)
    perform
  end

  context 'with an unmasked sibling attachment' do
    let!(:sibling) do
      FactoryBot.create(
        :body_text, :unmasked, incoming_message: incoming_message
      )
    end

    it 'masks the sibling and erases the attachment' do
      perform
      expect(sibling.reload).to be_masked
      expect(attachment.reload).to be_erased
    end
  end
end
