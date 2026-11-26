require 'spec_helper'

RSpec.describe 'Embedded font masking' do
  include TrueTypeFixtures

  let(:font_bytes) do
    true_type_font([1, 0, cmap_zero(65 => 7)],
                   [3, 1, cmap_six(0x03BB, [7])])
  end
  let(:pdf) { embedded_font_pdf(font_bytes) }
  let(:masker) { Class.new { include AlaveteliTextMasker }.new }

  it 'masks text decoded through the embedded program in a PDF content stream' do
    rule = PDFRedactor::Rule.new(/\u03BB/, true, nil, "\u03BB")
    masked, report = PDFRedactor.redact(pdf, [rule])
    expect(report['matches']).to eq(1)
    expect(report['glyphs_censored']).to eq(1)
    expect(report['boxes']).to eq(1)
    expect(masked).to start_with('%PDF')
    expect(PDFRedactor.redact(masked, [rule]).last['matches']).to eq(0)
  end

  it 'turns a parser work limit into the normal PDF masking error' do
    stub_const('PDFRedactor::TrueTypeProgram::MAX_WORK', 16)
    expect { masker.apply_masks(pdf, 'application/pdf') }.
      to raise_error(AlaveteliTextMasker::PDFMaskingError, /font.*work limit/i)
  end

  # A fault, so the requester gets the PDF as it came, and it can't go
  # public (FoiAttachment::Maskable#masking_outcome).
  it 'records a font work failure as a fault' do
    attachment = FactoryBot.create(:pdf_attachment, :unmasked)
    FactoryBot.create(:info_request_censor_rule,
                      censorable: attachment.info_request, text: 'Zebracorn',
                      colour: 'black')
    attachment.replace_file!(pdf)
    stub_const('PDFRedactor::TrueTypeProgram::MAX_WORK', 16)
    attachment.mask
    expect(attachment.masking_error).
      to be_a(AlaveteliTextMasker::PDFMaskingError)
    expect(attachment.masking_error.message).to include('work limit')
    expect(attachment.reload.masking_failed_at).to be_present
    expect(attachment.masking_fault&.first).to eq(:as_it_came)
  end

  it 'rejects a malformed embedded program instead of silently losing its text' do
    broken = embedded_font_pdf(font_bytes.byteslice(0, 20))
    expect { masker.apply_masks(broken, 'application/pdf') }.
      to raise_error(AlaveteliTextMasker::PDFMaskingError, /font.*bounds/i)
  end
end
