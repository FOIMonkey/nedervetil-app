require 'spec_helper'
require Rails.root.join(
  'db/migrate', '20261106130000_fold_requester_only_messages_into_normal'
).to_s

RSpec.describe FoldRequesterOnlyMessagesIntoNormal do
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages do
      described_class.migrate(direction)
    end
  end

  let(:request) { FactoryBot.create(:info_request_with_pdf_attachment) }
  let(:reply) { request.incoming_messages.first }
  let(:outgoing) { request.outgoing_messages.first }
  let(:file) { reply.foi_attachments.first }

  # Written directly, as validation refuses requester_only for a message.
  def at(record, prominence)
    record.update_columns(prominence: prominence)
    record
  end

  it 'makes a requester_only message normal, and leaves files and the rest' do
    folded = [at(reply, 'requester_only'), at(outgoing, 'requester_only')]
    hidden = at(FactoryBot.create(:incoming_message, info_request: request),
                'hidden')
    kept = at(file, 'requester_only')

    migrate(:up)

    expect(folded.map { _1.reload.prominence }).to eq(%w[normal normal])
    expect(hidden.reload.prominence).to eq('hidden')
    expect(kept.reload.prominence).to eq('requester_only')
  end

  it 'changes nothing on the way down' do
    at(reply, 'requester_only')
    migrate(:up)
    migrate(:down)
    expect(reply.reload.prominence).to eq('normal')
  end
end
