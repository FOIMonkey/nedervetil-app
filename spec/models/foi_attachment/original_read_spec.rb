require 'spec_helper'

RSpec.describe FoiAttachment, 'reading its original part' do
  include MailReadHelpers

  let(:info_request) { FactoryBot.create(:info_request) }
  let(:message) do
    receive_incoming_mail('incoming-request-two-same-name.eml',
                          to: info_request.incoming_email)
    info_request.incoming_messages.last.tap(&:parse_raw_email!)
  end
  let(:attachment) do
    message.foi_attachments.to_a.last.tap(&:mask)
  end

  describe '#mail_attributes' do
    it 'asks for its own part only' do
      attachment
      reads = watch_mail_reads

      expect(attachment.unmasked_body).to include('hello')
      expect(reads.map { |read| read[:options] }).
        to eq([{ part: attachment.hexdigest }])
    end

    it 'finds a part whose digest has changed by its stored file, in a ' \
       'second read, and takes the part’s digest' do
      digest = attachment.hexdigest
      attachment.update_column(:hexdigest, '0' * 32)
      reads = watch_mail_reads

      expect(attachment.unmasked_body).to include('hello')
      expect(reads.map { |read| read[:options].keys }).
        to eq([[:part], [:stored]])
      expect(attachment.reload.hexdigest).to eq(digest)
    end

    it 'is missing when neither read finds it' do
      attachment.update_column(:hexdigest, '0' * 32)
      attachment.file.blob.upload(StringIO.new('nothing like it'))

      expect { attachment.unmasked_body }.to raise_error(
        FoiAttachment::MissingError, /missing in raw email/
      )
    end

    it 'is missing when it has no stored file to be found by' do
      attachment.update_column(:hexdigest, '0' * 32)
      attachment.file.blob.service.delete(attachment.file.blob.key)

      expect { attachment.unmasked_body }.to raise_error(
        FoiAttachment::MissingError, /missing from storage/
      )
    end

    it 'lets a refused read through' do
      attachment
      refuse_mail_reads

      expect { attachment.unmasked_body }.
        to raise_error(MailHandler::ReadRefused)
    end
  end

  describe '#mask' do
    it 'masks the stored file in place without reading RawEmail' do
      attachment.update_column(:masked_at, nil)
      reads = watch_mail_reads

      attachment.mask

      expect(reads).to be_empty
      expect(attachment.reload).to be_masked
    end
  end
end
