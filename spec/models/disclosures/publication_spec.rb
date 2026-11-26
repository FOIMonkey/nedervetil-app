require 'spec_helper'

RSpec.describe Disclosures::Publication do
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Library budget 2026')
  end

  describe '#publish!' do
    context 'when a refused attempt’s uploads can’t be deleted' do
      let(:document) do
        pdf = DocumentFixtures.text_pdf(title: 'Budget',
                                        paragraphs: ['Books: 400 pounds.'])
        delivered_document(info_request, 'budget.pdf', 'application/pdf', pdf)
      end
      let(:logged) { [] }

      before do
        allow(Rails.logger).to receive(:warn) { |line| logged << line }
        storage = ActiveStorage::Blob.services.fetch(:attachments)
        allow(Disclosures::TopicMatch).to receive(:record) do
          allow(storage).to receive(:delete).
            and_raise(Errno::EACCES, 'a storage path')
          raise Disclosures::Error::Refused, 'Stopped after rendering'
        end
      end

      it 'still raises the refusal' do
        expect { described_class.new(document, user: owner).publish! }.
          to raise_error(Disclosures::Error::Refused, 'Stopped after rendering')
        expect(document.reload.state).to eq('draft')
      end

      it 'logs the document and the error’s class, not its message' do
        expect { described_class.new(document, user: owner).publish! }.
          to raise_error(Disclosures::Error::Refused)

        expect(logged).to include(
          "publication_upload_cleanup_failed document_id=#{document.id} " \
          'Errno::EACCES'
        )
        expect(logged.join("\n")).not_to include('a storage path')
      end
    end
  end
end
