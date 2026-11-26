require 'spec_helper'

RSpec.describe Disclosures::NameMask do
  describe '.pdf_had_name?' do
    context 'when the scan fails' do
      let(:logged) { [] }

      before do
        allow(Rails.logger).to receive(:warn) { |line| logged << line }
        allow(PDFRedactor::FinalScan).to receive(:check!).
          and_raise(PDFRedactor::Error, 'Text from the file')
      end

      it 'answers that the name wasn’t there' do
        expect(described_class.pdf_had_name?('%PDF-1.7', [])).to be(false)
      end

      it 'logs the error’s class, not its message' do
        described_class.pdf_had_name?('%PDF-1.7', [])

        expect(logged).to eq(['name_mask_pdf_scan_failed PDFRedactor::Error'])
      end
    end
  end
end
