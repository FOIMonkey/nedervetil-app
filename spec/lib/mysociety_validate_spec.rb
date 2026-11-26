require 'rspec/core'
require_relative '../../vendor/mysociety/rblib/validate'

RSpec.describe MySociety::Validate do
  describe '.is_valid_email' do
    it 'accepts an address only when it occupies the whole string' do
      expect(described_class.is_valid_email('person@example.org')).to be_truthy
      expect(described_class.is_valid_email("other\nperson@example.org")).
        to be_nil
      expect(described_class.is_valid_email("person@example.org\nother")).
        to be_nil
      expect(described_class.is_valid_email("person@example.org\n")).to be_nil
    end
  end

  describe '.is_valid_postcode' do
    it 'rejects surrounding lines' do
      expect(described_class.is_valid_postcode('SW1A 1AA')).to be(true)
      expect(described_class.is_valid_postcode("SW1A 1AA\nother")).to be(false)
      expect(described_class.is_valid_postcode("other\nSW1A 1AA")).to be(false)
      expect(described_class.is_valid_postcode("SW1A 1AA\n")).to be(false)
    end
  end

  describe '.is_valid_partial_postcode' do
    it 'rejects surrounding lines' do
      expect(described_class.is_valid_partial_postcode('SW1A')).to be(true)
      expect(described_class.is_valid_partial_postcode("SW1A\nother")).
        to be(false)
      expect(described_class.is_valid_partial_postcode("other\nSW1A")).
        to be(false)
      expect(described_class.is_valid_partial_postcode("SW1A\n")).to be(false)
      expect(described_class.is_valid_partial_postcode("zz9\nother")).
        to be(false)
    end
  end
end
