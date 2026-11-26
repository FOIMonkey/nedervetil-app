require_relative 'spec_helper'

RSpec.describe PDFRedactor::Survey do
  def helvetica
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
  end

  # One grey pixel, drawn as large as the content's cm says.
  def pixel
    "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 " \
      "/ColorSpace /DeviceGray /BitsPerComponent 8 /Length 1 >>\n" \
      "stream\n\x80\nendstream".b
  end

  def pdf(content, font: helvetica)
    AttachmentFixtures.write(
      ['<< /Type /Catalog /Pages 2 0 R >>',
       '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
       '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
       '/Resources << /Font << /F1 4 0 R >> /XObject << /Im1 6 0 R >> >> ' \
       '/Contents 5 0 R >>',
       font,
       "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream",
       pixel],
      root: 1, info: nil
    )
  end

  it 'counts the glyphs that map to text, and the share pictures cover' do
    page, = described_class.pages(
      pdf('BT /F1 12 Tf 72 760 Td (Road contracts) Tj ET ' \
          'q 200 0 0 100 72 400 cm /Im1 Do Q')
    )

    expect(page).to include('number' => 1, 'visible' => 13,
                            'unmapped' => 0)
    expect(page['picture_share']).to be_within(0.0001).
      of(20_000.0 / (595 * 842))
  end

  # Codes above ASCII, named in the encoding by names that mean nothing:
  # a printable ASCII code would be read as itself (Font#last_resort).
  it 'counts glyphs whose codes map to no text' do
    font = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' \
           '/Encoding << /Type /Encoding /Differences [144 /zz1 /zz2 /zz3] ' \
           '>> >>'
    page, = described_class.pages(
      pdf('BT /F1 12 Tf 72 760 Td (\220\221\222\220\221\222) Tj ET',
          font: font)
    )

    expect(page).to include('visible' => 0, 'unmapped' => 6,
                            'picture_share' => 0.0)
  end
end
