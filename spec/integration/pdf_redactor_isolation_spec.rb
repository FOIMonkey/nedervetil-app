require 'spec_helper'

RSpec.describe 'PDFRedactor in the bubblewrap worker' do
  let(:rule) { PDFRedactor::Rule.new(/Zebracorn/, true, nil, 'Zebracorn') }
  let(:letter) do
    AttachmentFixtures.pdf(
      pages: [AttachmentFixtures.letter_page(secret: 'Meeting with Zebracorn')]
    )
  end

  before do
    allow(AlaveteliConfiguration).to receive(:sandbox_converters).
      and_return('required')
    problem = AlaveteliSandbox.volume_problem
    skip "the sandbox can't run here: #{problem}" if problem
    begin
      AlaveteliSandbox.self_test
    rescue AlaveteliSandbox::Error => e
      skip "the sandbox can't run here: #{e.message}"
    end
  end

  def text_of(pdf)
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, 'c.pdf'), pdf)
      AttachmentFixtures.pdf_text(File.join(dir, 'c.pdf'))
    end
  end

  it 'masks a PDF there, with nothing parsed here' do
    expect(PDFRedactor::QdfDoc).not_to receive(:new)

    masked, report = PDFRedactor.redact(letter, [rule])

    expect(report['rules_matched']).to eq([0])
    expect(text_of(masked)).to include('Meeting with')
    expect(text_of(masked)).not_to include('Zebracorn')
  end

  it 'reads a PDF whole there' do
    expect(PDFRedactor::QdfDoc).not_to receive(:new)

    expect { PDFRedactor::FinalScan.check!(letter, [rule]) }.
      to raise_error(PDFRedactor::Matched, /still matches/)
  end

  it 'checks a PDF’s pictures there' do
    expect(PDFRedactor::QdfDoc).not_to receive(:new)
    expect(PDFRedactor::PictureCover.first_page(letter)).to be_nil
  end

  it 'surveys a PDF’s pages there' do
    expect(PDFRedactor::QdfDoc).not_to receive(:new)

    page, = PDFRedactor::Survey.pages(letter)
    expect(page).to include('number' => 1, 'unmapped' => 0)
    expect(page['visible']).to be_positive
  end

  it 'passes its self-test there, as the health check runs it' do
    expect(PDFRedactor::QdfDoc).not_to receive(:new)
    expect { PDFRedactor::Isolated.self_test }.not_to raise_error
  end

  it 'reports a PDF that needs a password' do
    locked = AttachmentFixtures.encrypted_pdf(letter)
    expect { PDFRedactor.redact(locked, [rule]) }.
      to raise_error(PDFRedactor::PasswordRequired)
  end

  it 'fails a parser limit there as an error' do
    content = "#{'[' * 129}0#{']' * 129} noop"
    nested = AttachmentFixtures.write(
      ['<< /Type /Catalog /Pages 2 0 R >>',
       '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
       '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
       '/Contents 4 0 R >>',
       "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream"],
      root: 1, info: nil
    )

    expect { PDFRedactor.redact(nested, [rule]) }.
      to raise_error(PDFRedactor::Error, /nesting limit/)
  end
end
