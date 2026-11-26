require 'spec_helper'

RSpec.describe PDFRedactor, 'isolation' do
  let(:rules) { [PDFRedactor::Rule.new(/Zebracorn/, true, nil, 'Zebracorn')] }
  let(:pdf) { '%PDF-1.4 synthetic' }

  def stderr(line)
    Struct.new(:stderr).new(line)
  end

  context 'when the sandbox is required' do
    before { allow(AlaveteliSandbox).to receive(:required?).and_return(true) }

    it 'masks in the worker' do
      expect(described_class::Isolated).to receive(:redact).
        with(pdf, rules, ocr: false, depth: 0, final_scan: false).
        and_return(['%PDF masked', {}])
      expect(described_class::Redactor).not_to receive(:new)

      expect(described_class.redact(pdf, rules).first).to eq('%PDF masked')
    end

    it 'reads a file whole in the worker' do
      expect(described_class::Isolated).to receive(:final_scan).
        with(pdf, rules)
      expect(described_class::QdfDoc).not_to receive(:new)

      described_class::FinalScan.check!(pdf, rules)
    end

    it 'tells a rule match from a failure when the worker reads a file whole' do
      ended = ->(line) { AlaveteliSandbox::Failed.new('exit 2', stderr(line)) }
      allow(AlaveteliSandbox).to receive(:job).and_raise(
        ended.call("PDFRedactor::Matched: a rule still matches in object 4\n")
      )
      expect { described_class::Isolated.final_scan(pdf, rules) }.
        to raise_error(described_class::Matched, /still matches/)

      allow(AlaveteliSandbox).to receive(:job).and_raise(
        ended.call("PDFRedactor::Error: object 4 holds a zip file\n")
      )
      expect { described_class::Isolated.final_scan(pdf, rules) }.
        to raise_error(described_class::Error) { |error|
          expect(error).not_to be_a(described_class::Matched)
        }
    end

    it 'checks a file’s pictures in the worker' do
      expect(described_class::Isolated).to receive(:picture_cover).
        with(pdf).and_return(2)
      expect(described_class::QdfDoc).not_to receive(:new)

      expect(described_class::PictureCover.first_page(pdf)).to eq(2)
    end

    it 'surveys pages in the worker' do
      expect(described_class::Isolated).to receive(:survey).with(pdf).
        and_return([])
      expect(described_class::QdfDoc).not_to receive(:new)

      expect(described_class::Survey.pages(pdf)).to eq([])
    end

    it 'turns a limit hit in the worker into a fault' do
      allow(described_class::Isolated).to receive(:redact).
        and_raise(described_class::Error, 'PDF redactor failed: timed out')
      attachment = FactoryBot.create(:pdf_attachment, :unmasked)
      FactoryBot.create(:info_request_censor_rule,
                        censorable: attachment.info_request, text: 'Zebracorn')

      attachment.mask

      expect(attachment.reload).to be_masking_failed
      expect(attachment.masking_fault).to eq(
        [:as_it_came, 'AlaveteliTextMasker::PDFMaskingError: ' \
                      'PDFRedactor::Error: PDF redactor failed: timed out']
      )
    end
  end

  context 'when the sandbox is off' do
    before { allow(AlaveteliSandbox).to receive(:required?).and_return(false) }

    it 'masks here' do
      expect(described_class::Isolated).not_to receive(:redact)
      expect { described_class.redact(pdf, rules) }.
        to raise_error(AlaveteliSandbox::Failed)
    end
  end
end
