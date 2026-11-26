require 'spec_helper'

RSpec.describe Whitespace do
  # Each rule against the strip_attributes options it replaces, including
  # bytes that aren't text (the gem's ASCII-only fallback) and non-strings.
  describe 'compared with strip_attributes' do
    values = [
      ' a ', "\ta b\n", "\u00A0a\u2003", "\u200Ba\uFEFF", "\u3000x\u180E",
      "a\r\nb", "a\n\nb", "a \t  b", '   ', '', "\u200B",
      " a\xA0 \r\n".b, "a \t  b\r\nc\xA0".b, " \t ".b, nil, 3
    ]
    rules = {
      trim: { allow_empty: true },
      trim_to_nil: {},
      one_line: { replace_newlines: true, collapse_spaces: true }
    }

    rules.each do |rule, options|
      it "#{rule} does what strip_attributes(#{options}) did" do
        aggregate_failures do
          values.each do |value|
            expect(described_class.public_send(rule, value.dup)).
              to eq(LegacyStripAttributes.strip(value.dup, **options)),
                 "for #{value.inspect}"
          end
        end
      end
    end
  end

  describe '.trim' do
    it 'trims spaces, tabs and line breaks from both ends' do
      expect(described_class.trim(" \t a  b \r\n")).to eq('a  b')
    end

    it 'trims Unicode spaces and invisible characters from both ends' do
      expect(described_class.trim("\u00A0\u200Ba\u3000\uFEFF")).to eq('a')
    end

    it 'keeps a blank value as an empty string' do
      expect(described_class.trim(" \u200B ")).to eq('')
    end

    it 'trims only ASCII whitespace from bytes that are not text' do
      value = " a\xA0 ".dup.force_encoding(Encoding::BINARY)
      expect(described_class.trim(value)).to eq("a\xA0".b)
    end

    it 'returns anything but a string as it is' do
      expect(described_class.trim(3)).to eq(3)
    end

    it 'leaves the value it was given unchanged' do
      value = +' a '
      described_class.trim(value)
      expect(value).to eq(' a ')
    end
  end

  describe '.trim_to_nil' do
    it 'trims a value' do
      expect(described_class.trim_to_nil("\n a ")).to eq('a')
    end

    it 'turns a blank value into nil' do
      expect(described_class.trim_to_nil(" \u200B\t")).to be_nil
    end
  end

  describe '.one_line' do
    it 'turns each run of line breaks into one space' do
      expect(described_class.one_line("a\r\n\r\nb\nc")).to eq('a b c')
    end

    it 'turns each run of spaces and tabs into one space' do
      expect(described_class.one_line("a \t\u00A0 b")).to eq('a b')
    end

    it 'trims the ends first' do
      expect(described_class.one_line("\n a \n")).to eq('a')
    end

    it 'turns a blank value into nil' do
      expect(described_class.one_line(" \r\n ")).to be_nil
    end
  end
end
