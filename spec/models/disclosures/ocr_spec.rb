require 'spec_helper'

# Turning off AI reading stops replies going to an AI service outside the site.
# OCR runs on this server, so it still runs for a requester who turned it off.
RSpec.describe 'Disclosures OCR' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Gritting routes 2024')
  end
  let(:scan) do
    DocumentFixtures.scanned_pdf(lines: ['Gritting runs by ward',
                                         'North depot: twelve runs in January'])
  end

  def scanned_document
    message = AttachmentFixtures.deliver(
      info_request, [['scan.pdf', 'application/pdf', scan]]
    )
    attachment = message.get_attachments_for_display.
      find { |a| a.filename == 'scan.pdf' }
    document = Disclosures::Creation.new(user: owner,
                                         attachment: attachment,
                                         kind: 'released_records').create!
    Disclosures::Renderer.new(document).run
    document.reload
  end

  it 'reads a scanned page on this server, also for a requester who switched off AI reading' do
    skip 'Tesseract, pdftoppm or prlimit not installed' unless ocr_tools?
    Disclosures.ocr = true
    IncomingAttention::OptOut.set!(owner, true)

    document = scanned_document
    page = document.pages.first
    expect(page.text_source).to eq('ocr')
    expect(page.text.strip).not_to be_empty
    expect(document.render_notes).to include('ocr' => 'on', 'ocr_pages' => 1)
    expect(Disclosures::Checks.unreadable_pages(document)).to be_empty
  end

  it 'leaves a scanned page without text when OCR is off, and lists it for checking by eye' do
    document = scanned_document
    page = document.pages.first
    expect(page).
      to have_attributes(kind: 'image', text_source: 'none', text: '')
    expect(page.image).to be_attached
    expect(document.render_notes).to include('ocr' => 'off')
    expect(Disclosures::Checks.unreadable_pages(document)).to eq([page])
  end
end
