require 'spec_helper'

RSpec.describe 'OCR of pictures and unmapped text at publication' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Road contracts')
  end
  let(:email) { 'officer@synthetic-authority.test' }
  let(:text) do
    'BT /F1 12 Tf 72 760 Td (The council replied about the road ' \
    'contracts, with its letterhead below.) Tj ET'
  end

  def letter_with_picture(width: 400, height: 100)
    jpeg = AttachmentFixtures.image(lines: [[30, 120, email]], width: 1200,
                                    height: 300, format: 'jpg',
                                    point_size: 60)
    pixels_wide, pixels_high, components = DocumentFixtures.jpeg_size(jpeg)
    space = { 1 => '/DeviceGray', 3 => '/DeviceRGB' }.fetch(components)
    content = "#{text} q #{width} 0 0 #{height} 72 300 cm /Im1 Do Q"
    AttachmentFixtures.write(
      ['<< /Type /Catalog /Pages 2 0 R >>',
       '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
       '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
       '/Resources << /Font << /F1 4 0 R >> /XObject << /Im1 6 0 R >> >> ' \
       '/Contents 5 0 R >>',
       '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
       "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream",
       "<< /Type /XObject /Subtype /Image /Width #{pixels_wide} " \
       "/Height #{pixels_high} /ColorSpace #{space} /BitsPerComponent 8 " \
       "/Filter /DCTDecode /Length #{jpeg.bytesize} >>\nstream\n".b +
         jpeg.b + "\nendstream".b],
      root: 1, info: nil
    )
  end

  def plain_letter
    AttachmentFixtures.pdf(
      pages: [AttachmentFixtures.letter_page(secret: 'Resurfacing, 1,200')]
    )
  end

  def rendered(pdf)
    message = AttachmentFixtures.deliver(
      info_request, [['letter.pdf', 'application/pdf', pdf]]
    )
    document = document_from_attachment(file_in(message, 'letter.pdf'),
                                        by: owner)
    Disclosures::Renderer.new(document).run
    document.reload
  end

  def survey_says(**page)
    allow(PDFRedactor::Survey).to receive(:pages).and_return(
      [{ 'number' => 1, 'visible' => 100, 'unmapped' => 0,
         'picture_share' => 0.0 }.merge(page.transform_keys(&:to_s))]
    )
  end

  it 'reads the pictures on a page with text, and flags an email they show' do
    skip 'Tesseract, pdftoppm or prlimit not installed' unless ocr_tools?
    Disclosures.ocr = true

    document = rendered(letter_with_picture)

    expect(document.render_notes['ocr_flagged']).to eq('1' => ['pictures'])
    expect(document.render_notes['masked_pages']).to eq([1])
    expect(document.pages.first.text_source).to eq('pdftotext')
  end

  it 'lists a picture it couldn’t read when OCR is off' do
    document = rendered(letter_with_picture)

    expect(document.render_notes['unread_flagged']).
      to eq([{ 'page' => 1, 'reasons' => ['pictures'] }])
    expect(Disclosures::Checks.partial(document).map(&:what)).
      to include(a_string_including('its pictures couldn’t be read'))
  end

  it 'leaves a picture under 1% of the page alone' do
    document = rendered(letter_with_picture(width: 40, height: 10))

    expect(document.render_notes).not_to include('ocr_flagged',
                                                 'unread_flagged')
    expect(Disclosures::Checks.partial(document)).to be_empty
  end

  context 'with OCR on' do
    before do
      allow(Disclosures).to receive(:ocr?).and_return(true)
      allow(Disclosures::Ocr).to receive(:pdf_page).
        and_return("Write to #{email} about the contracts")
    end

    it 'reads a page whose glyphs map to no text, and flags what it shows' do
      survey_says(visible: 100, unmapped: 20)

      document = rendered(plain_letter)

      expect(document.render_notes['ocr_flagged']).to eq('1' => ['glyphs'])
      expect(document.render_notes['masked_pages']).to eq([1])
    end

    it 'leaves a page with fewer unmapped glyphs, or under a tenth, alone' do
      [{ visible: 100, unmapped: 19 }, { visible: 300, unmapped: 20 }].
        each do |counts|
          survey_says(**counts)
          document = rendered(plain_letter)

          expect(document.render_notes).not_to include('ocr_flagged')
          expect(Array(document.render_notes['masked_pages'])).to be_empty
        end
    end

    it 'reads every page with text when the survey fails' do
      allow(PDFRedactor::Survey).to receive(:pages).
        and_raise(PDFRedactor::Error, 'PDF redactor failed: timed out')

      document = rendered(plain_letter)

      expect(document.render_notes['ocr_flagged']).to eq('1' => ['unsurveyed'])
    end
  end

  it 'doesn’t survey or read pictures as a file comes in' do
    FactoryBot.create(:info_request_censor_rule,
                      censorable: info_request, text: 'letterhead')
    expect(PDFRedactor::Survey).not_to receive(:pages)
    message = AttachmentFixtures.deliver(
      info_request, [['letter.pdf', 'application/pdf', letter_with_picture]]
    )

    file_in(message, 'letter.pdf').mask
  end
end
