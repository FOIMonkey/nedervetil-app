require 'spec_helper'

RSpec.describe 'Disclosures misuse safeguards' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Gritting routes 2024')
  end
  let(:text) { "Gritting by ward\nNorth: 12 runs\nOfficer: Jane Placeholder\n" }
  let(:redacted) { text.sub('Jane Placeholder', '[redacted]') }

  around do |example|
    keeping_settings(Disclosures, :daily_documents) do
      example.run
    end
  end

  describe 'daily limits' do
    it 'refuses a requester’s documents past the day’s limit, counting only the last 24 hours, but not an admin’s' do
      Disclosures.daily_documents = 2
      message = AttachmentFixtures.deliver(
        info_request,
        (1..4).map { |n| ["part#{n}.txt", 'text/plain', "Part #{n}\n"] }
      )
      parts = (1..4).map do |n|
        message.get_attachments_for_display.
          find { |a| a.filename == "part#{n}.txt" }
      end
      make = ->(user, part) do
        Disclosures::Creation.new(user: user,
                                  attachment: part,
                                  kind: 'released_records').create!
      end
      make.call(owner, parts[0]).update_columns(created_at: 25.hours.ago)
      make.call(owner, parts[1])
      make.call(owner, parts[2])

      sign_in(owner)
      document_request :post, '/documents',
           params: { attachment_id: parts[3].id, kind: 'released_records' }
      expect(response).to redirect_to("/request/#{info_request.url_title}")
      expect(flash[:error]).
        to eq('You can share 2 documents a day. Your files stay private. ' \
                'Try again tomorrow.')
      expect(Disclosures::Document.where(foi_attachment: parts[3])).to be_empty

      Disclosures.daily_documents = 0
      expect(make.call(admin, parts[3])).to be_persisted
    end

    it 'still counts drafts the requester made and deleted' do
      allow(Rails).
        to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      Disclosures.daily_documents = 2
      message = AttachmentFixtures.deliver(
        info_request, [['loop.txt', 'text/plain', "Loop\n"]]
      )
      part = message.get_attachments_for_display.
        find { |a| a.filename == 'loop.txt' }
      make = -> do
        Disclosures::Creation.new(user: owner,
                                  attachment: part,
                                  kind: 'released_records').create!
      end

      2.times { make.call.destroy! }
      expect(Disclosures::Document.where(created_by: owner)).to be_empty
      expect { make.call }.
        to raise_error(Disclosures::Error::Refused, /share 2 documents a day/)
    end
  end
end
