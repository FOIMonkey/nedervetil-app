require 'spec_helper'

RSpec.describe AlaveteliFileTypes do
  describe '.filename_to_mimetype' do
    it 'maps xlsm to the macro-enabled Excel type' do
      expect(described_class.filename_to_mimetype('report.xlsm')).
        to eq('application/vnd.ms-excel.sheet.macroenabled.12')
    end

    it 'maps docm to the macro-enabled Word type' do
      expect(described_class.filename_to_mimetype('report.docm')).
        to eq('application/vnd.ms-word.document.macroenabled.12')
    end
  end

  describe '.mimetype_to_extension' do
    it 'maps the macro-enabled Excel type back to xlsm' do
      expect(
        described_class.mimetype_to_extension(
          'application/vnd.ms-excel.sheet.macroenabled.12'
        )
      ).to eq('xlsm')
    end
  end

  describe '.text_content?' do
    it 'does not mutate caller string encoding and accepts frozen strings' do
      binary = 'plain ascii'.b.freeze
      expect(described_class.text_content?(binary)).to be(true)
      expect(binary.encoding).to eq(Encoding::BINARY)

      mutable = 'hello'.b
      expect(described_class.text_content?(mutable)).to be(true)
      expect(mutable.encoding).to eq(Encoding::BINARY)
    end
  end
end
