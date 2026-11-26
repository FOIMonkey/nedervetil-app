require 'spec_helper'

RSpec.describe 'Removing an Office file’s metadata as it is published',
               type: :request do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:owner) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:docx_type) { Disclosures::Formats::DOCUMENT['.docx'] }
  let(:w) { OfficeFixtures::W }
  let(:docx) do
    OfficeFixtures.word(
      '<w:p><w:r><w:t xml:space="preserve">Keep </w:t></w:r>' \
      '<w:del w:id="1" w:author="Jane Example"><w:r>' \
      '<w:delText>gone </w:delText></w:r></w:del>' \
      '<w:ins w:id="2" w:author="Jane Example"><w:r><w:t>added</w:t>' \
      '</w:r></w:ins><w:commentRangeStart w:id="3"/>' \
      '<w:r><w:commentReference w:id="3"/></w:r></w:p>',
      parts: {
        'word/comments.xml' => [
          "#{OfficeFixtures::CT}wordprocessingml.comments+xml",
          "<w:comments #{w}><w:comment w:id=\"3\" w:author=\"Jane Example\">" \
          '<w:p><w:r><w:t>Check with legal</w:t></w:r></w:p></w:comment>' \
          '</w:comments>'
        ]
      },
      document_rels: [['rId9', "#{OfficeFixtures::R}comments",
                       'comments.xml']]
    )
  end

  def removal(on)
    allow(AlaveteliConfiguration).
      to receive(:disclosures_remove_office_metadata).and_return(on)
  end

  def left(bytes)
    OfficePackage::Tidy.new(OfficePackage.read(bytes)).survey
  end

  def published(bytes = docx, name = 'briefing.docx', type = docx_type)
    document = delivered_document(info_request, name, type, bytes, by: admin)
    publish(document, by: admin)
    get disclosure_document_download_path(document)
    expect(response).to have_http_status(:ok)
    [document, response.body.b]
  end

  let(:plain) do
    OfficeFixtures.word('<w:p><w:r><w:t>Nothing hidden here</w:t></w:r></w:p>',
                        core: nil)
  end

  # An admin's replacement of the published file with these bytes. Returns
  # what the thread then holds.
  def replaced_with(document, bytes)
    attachment = FoiAttachment.find(document.foi_attachment.id)
    current = attachment.file.download
    revision = AttachmentManagement::Revision.create!(
      foi_attachment: attachment, user: admin, kind: 'upload',
      status: 'ready', source_sha256: Digest::SHA256.hexdigest(current),
      source_content_type: attachment.content_type,
      source_filename: attachment.display_filename,
      output_sha256: Digest::SHA256.hexdigest(bytes),
      output_content_type: docx_type,
      output_filename: attachment.display_filename,
      output_byte_size: bytes.bytesize
    )
    revision.output.attach(io: StringIO.new(bytes),
                           filename: revision.output_filename,
                           content_type: docx_type)
    AttachmentManagement::Replacement.new(revision, editor: admin,
                                                    reason: 'Clean copy').apply!
    attachment.reload.file.download.b
  end

  it 'has tracked changes and comments to remove' do
    expect(left(docx)).to include('tracked_changes' => be_positive,
                                  'comments' => be_positive)
  end

  context 'when it is off' do
    before { removal(false) }

    it 'publishes the file as it was received' do
      _document, downloaded = published
      expect(downloaded).to eq(docx.b)
    end

    it 'keeps an admin’s replacement of a published file as it was given' do
      document, _downloaded = published(plain)
      expect(replaced_with(document, docx)).to eq(docx.b)
    end
  end

  context 'when it is on' do
    before { removal(true) }

    it 'publishes the file without its tracked changes and comments' do
      document, downloaded = published
      expect(downloaded).not_to eq(docx.b)
      expect(left(downloaded)['tracked_changes'].to_i).to eq(0)
      expect(left(downloaded)['comments'].to_i).to eq(0)
      text = OfficePackage.read(downloaded).read('word/document.xml')
      expect(text).to include('Keep ', 'added')
      expect(text).not_to include('gone')
      expect(document.foi_attachment.reload.file.download.b).to eq(downloaded)
      expect(document.reload.pages.map(&:text).join).to include('Keep added')
    end

    it 'tidies an admin’s replacement of a published file' do
      document, _downloaded = published(plain)
      stored = replaced_with(document, docx)
      expect(left(stored)['tracked_changes'].to_i).to eq(0)
      expect(left(stored)['comments'].to_i).to eq(0)
    end

    it 'publishes a file with nothing to remove as it came' do
      expect(OfficePackage::Tidy.call(plain)).not_to be_changed
      _document, downloaded = published(plain)
      expect(downloaded).to eq(plain.b)
    end

    it 'keeps a published spreadsheet public once the analyser has read it' do
      book = DocumentFixtures.xlsx(
        sheets: [{ name: 'Shown', rows: [%w[Depot Vans], %w[North 12]] },
                 { name: 'Gone', rows: [['x']], hidden: true }],
        creator: 'Jane Example'
      )
      expect(OfficePackage::Tidy.call(book)).to be_changed
      document, downloaded = published(
        book, 'fleet.xlsx', Disclosures::Formats::SPREADSHEET['.xlsx']
      )
      expect(downloaded).not_to eq(book.b)
      perform_enqueued_jobs(only: ActiveStorage::AnalyzeJob)
      expect(document.foi_attachment.reload).to be_is_public
      expect(document.reload).to be_listed
      get disclosure_document_download_path(document)
      expect(response).to have_http_status(:ok)
    end

    it 'leaves an .xls as it came' do
      xls = File.binread(Rails.root.join('gems/excel_analyzer/spec/fixtures/' \
                                         'data.xls'))
      _document, downloaded = published(xls, 'budget.xls',
                                        'application/vnd.ms-excel')
      expect(downloaded).to eq(xls.b)
    end

    it 'publishes nothing when the file can’t be tidied' do
      document = delivered_document(info_request, 'briefing.docx', docx_type,
                                    docx, by: admin)
      # Read here, where Tidy can be made to fail.
      allow(AlaveteliConfiguration).to receive(:sandbox_converters).
        and_return('off')
      allow(OfficePackage::Tidy).to receive(:call).
        and_raise(OfficePackage::Error, 'comments could not be removed')
      expect { Disclosures::Publication.new(document, user: admin).publish! }.
        to raise_error(Disclosures::Error::Refused,
                       /couldn’t remove the hidden/)
      expect(document.reload).not_to be_listed
      expect(document.foi_attachment.reload.file.download.b).to eq(docx.b)
    end
  end
end
