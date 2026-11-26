require 'spec_helper'

RSpec.describe FoiAttachment::StoredFile do
  include ActiveJob::TestHelper

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request) }
  let(:raw) { "Synthetic notes naming Zebracorn.\n" }

  def delivered
    message = AttachmentFixtures.deliver(info_request,
                                         [['notes.txt', 'text/plain', raw]])
    attachment = message.get_attachments_for_display.
                 find { |part| part.filename == 'notes.txt' }
    FoiAttachment.find(attachment.id)
  end

  def in_state(state)
    attachment = delivered
    case state
    when :unmasked
      attachment.update_column(:masked_at, nil)
    when :masked
      attachment.mask
    when :failed
      attachment.update_column(:masking_failed_at, Time.zone.now)
    end
    FoiAttachment.find(attachment.id).
      tap { |made| expect(made.stored_state).to eq(state) }
  end

  def stored(attachment)
    FoiAttachment.find(attachment.id).file.download
  end

  it 'names erased attachments' do
    expect(FactoryBot.create(:body_text, :erased).stored_state).to eq(:erased)
  end

  describe 'masking writing the file' do
    %i[unmasked masked].each do |from|
      it "writes over #{from} in place" do
        attachment = in_state(from)
        blob_id = attachment.file_blob.id
        recorded = false
        expect(attachment.send(:store_masked!, 'Masked') { recorded = true }).
          to be(true)
        expect(recorded).to be(true)
        expect(stored(attachment)).to eq('Masked')
        expect(FoiAttachment.find(attachment.id).file_blob.id).to eq(blob_id)
      end
    end
  end

  it 'keeps its writes private' do
    attachment = FactoryBot.create(:body_text)
    %i[store_masked! upload_stored].each do |name|
      expect(attachment).not_to respond_to(name)
    end
    expect(attachment).to respond_to(:stored_state)
  end

  # Catches the usual ways to write a file through ActiveStorage, in app,
  # lib and rake tasks. It can't see a theme's or add-on's code, or a write
  # spelled some other way.
  it 'is the only code that writes an attachment’s stored file' do
    allowed = 'app/models/foi_attachment/stored_file.rb'
    anywhere = /\bfile_blob\s*&?\.\s*upload\w*|\bfile\.blob\s*&?\.\s*upload\w*/
    near_attachments = /\bfile\s*&?\.\s*attach\b|\bself\.file\s*=(?!=)|
                        \bfile_blob\.service\.upload|\bupdate!?\(\s*file:/x
    files = Dir[Rails.root.join('{app,lib}/**/*.{rb,rake}')]
    offenders = files.filter_map do |path|
      relative = path.delete_prefix("#{Rails.root}/")
      next if relative == allowed

      source = File.read(path)
      attachment_code = relative.match?(/foi_attachment|incoming_message|
                                         attachment_management|attachment|
                                         mail_handler/x)
      relative if source.match?(anywhere) ||
                  (attachment_code && source.match?(near_attachments))
    end
    expect(offenders).to eq([])
  end
end
