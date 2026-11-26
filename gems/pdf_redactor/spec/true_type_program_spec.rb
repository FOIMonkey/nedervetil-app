require_relative 'spec_helper'
require_relative '../../../spec/support/true_type_fixtures'

RSpec.describe PDFRedactor::TrueTypeProgram do
  include TrueTypeFixtures

  def program(data, pair = [3, 1])
    described_class.new(true_type_font([*pair, data]))
  end

  it 'reads a format 0 Macintosh map and ignores missing glyph zero' do
    font = program(cmap_zero(65 => 7), [1, 0])
    expect(font.glyph(65, [3, 0], [1, 0])).to eq(7)
    expect(font.glyph(66, [1, 0])).to be_nil
    expect(font.has?([1, 0])).to be(true)
    expect(font.has?([3, 0])).to be(false)
  end

  it 'reads format 4 delta ranges and the terminal sentinel' do
    font = program(cmap_four([[65, 66, -58]]))
    expect(font.glyph(65, [3, 1])).to eq(7)
    expect(font.glyph(66, [3, 1])).to eq(8)
    expect(font.glyph(0xFFFF, [3, 1])).to be_nil
    expect(font.unicode_of(7)).to eq('A')
  end

  it 'reads format 4 glyph-array offsets without applying delta to zero' do
    font = program(cmap_four([[65, 67, 2, [5, 0, 9]]]))
    expect([65, 66, 67].map { |code| font.glyph(code, [3, 1]) }).
      to eq([7, nil, 11])
  end

  it 'reads format 6 mappings and builds their Unicode inverse' do
    font = program(cmap_six(32, [1, 0, 2]), [0, 3])
    expect(font.glyph(33, [0, 3])).to be_nil
    expect(font.unicode_of(1)).to eq(' ')
    expect(font.unicode_of(2)).to eq('"')
  end

  it 'reads supplementary Unicode characters in format 12' do
    font = program(cmap_twelve([[0x1F600, 0x1F601, 30]]), [3, 10])
    expect(font.glyph(0x1F601, [3, 10])).to eq(31)
    expect(font.unicode_of(30)).to eq("\u{1F600}")
    expect(font.unicode_of(999)).to be_nil
  end

  it 'does not give the missing glyph or surrogate code points Unicode text' do
    font = program(cmap_six(0xD7FF, [0, 7]))
    expect(font.unicode_of(0)).to be_nil
    expect(font.unicode_of(7)).to be_nil
  end

  it 'prefers the full Unicode map when glyphs have more than one mapping' do
    data = true_type_font([3, 1, cmap_six(65, [7])],
                          [3, 10, cmap_twelve([[0x1F600, 0x1F600, 7]])])
    font = described_class.new(data)
    expect(font.unicode_of(7)).to eq("\u{1F600}")
  end

  it 'leaves an unsupported subtable format unmapped' do
    font = program([13, 0, 16, 0, 0].pack('nnNNN'))
    expect(font.has?([3, 1])).to be(false)
    expect(font.glyph(65, [3, 1])).to be_nil
  end

  it 'handles a valid sfnt header without a cmap' do
    font = described_class.new([0x00010000, 0, 0, 0, 0].pack('Nn4'))
    expect(font.has?([3, 1])).to be(false)
    expect(font.unicode_of(1)).to be_nil
  end

  it 'validates unused table bounds without copying their payloads' do
    cmap = true_type_font([3, 1, cmap_six(65, [7])]).byteslice(28..)
    unused_offset = 44 + cmap.bytesize
    data = [0x00010000, 2, 0, 0, 0].pack('Nn4') +
           ['cmap', 0, 44, cmap.bytesize].pack('a4N3') +
           ['glyf', 0, unused_offset, 1024].pack('a4N3') + cmap + ('x' * 1024)
    allow(data).to receive(:b).and_return(data)
    allow(data).to receive(:byteslice).and_call_original

    expect(described_class.new(data).glyph(65, [3, 1])).to eq(7)
    expect(data).not_to have_received(:byteslice).with(unused_offset, 1024)
  end

  it 'rejects truncated headers and directories' do
    data = true_type_font([3, 1, cmap_six(65, [7])])
    [0, 4, 11, 20, 27, data.bytesize - 1].each do |length|
      expect { described_class.new(data.byteslice(0, length)) }.
        to raise_error(described_class::InvalidFont)
    end
  end

  it 'rejects table offsets outside the font' do
    data = true_type_font([3, 1, cmap_six(65, [7])])
    data[20, 4] = [data.bytesize + 1].pack('N')
    expect { described_class.new(data) }.
      to raise_error(described_class::InvalidFont, /bounds/)
  end

  it 'rejects a subtable that escapes its declared cmap table' do
    data = true_type_font([3, 1, cmap_six(65, [7])])
    data[24, 4] = [12].pack('N')
    expect { described_class.new(data) }.
      to raise_error(described_class::InvalidFont, /bounds/)
  end

  it 'rejects overlapping format 4 segments before expanding them' do
    rows = Array.new(32) { [0, 0xFFFE, 1] }
    expect { program(cmap_four(rows)) }.
      to raise_error(described_class::InvalidFont, /overlap/)
  end

  it 'rejects format 4 tables without a sentinel' do
    expect { program(cmap_four([[65, 66, -58]], sentinel: false)) }.
      to raise_error(described_class::InvalidFont, /sentinel/)
  end

  it 'rejects odd format 4 segment counts' do
    data = cmap_four([[65, 66, -58]])
    data[6, 2] = [3].pack('n')
    expect { program(data) }.
      to raise_error(described_class::InvalidFont, /segment count/)
  end

  it 'rejects format 4 glyph offsets outside the subtable' do
    data = cmap_four([[65, 66, 0, [7, 8]]])
    data[28, 2] = [1000].pack('n')
    expect { program(data) }.
      to raise_error(described_class::InvalidFont, /bounds/)
  end

  it 'rejects a format 6 range beyond its 16-bit character space' do
    expect { program(cmap_six(0xFFFF, [7, 8])) }.
      to raise_error(described_class::InvalidFont, /range/)
  end

  [
    [[65, 70, 1], [69, 72, 10]],
    [[70, 65, 1]],
    [[0x110000, 0x110001, 1]],
    [[65, 66, 0xFFFF]]
  ].each do |groups|
    it "rejects invalid format 12 ranges: #{groups.inspect}" do
      expect { program(cmap_twelve(groups), [3, 10]) }.
        to raise_error(described_class::InvalidFont, /range/)
    end
  end

  it 'rejects a truncated format 12 group array' do
    data = cmap_twelve([[65, 66, 7]])
    data[12, 4] = [2].pack('N')
    expect { program(data, [3, 10]) }.
      to raise_error(described_class::InvalidFont, /bounds/)
  end

  it 'enforces a cumulative mapping budget across distinct subtables' do
    stub_const('PDFRedactor::TrueTypeProgram::MAX_WORK', 12)
    data = true_type_font(
      [3, 1, cmap_twelve([[65, 69, 1]])],
      [0, 3, cmap_twelve([[70, 74, 10]])]
    )
    expect { described_class.new(data) }.to raise_error(/work limit/)
  end

  it 'does not repeatedly expand shared subtable offsets or inverses' do
    stub_const('PDFRedactor::TrueTypeProgram::MAX_WORK', 16)
    table = cmap_twelve([[65, 69, 1]])
    font = described_class.new(true_type_font([3, 10, table], [0, 4, table]))
    expect(font.unicode_of(1)).to eq('A')
    expect(font.unicode_of(5)).to eq('E')
  end

  it 'includes inverse construction in the work budget' do
    stub_const('PDFRedactor::TrueTypeProgram::MAX_WORK', 8)
    font = program(cmap_twelve([[65, 69, 1]]), [3, 10])
    expect { font.unicode_of(1) }.to raise_error(/work limit/)
  end

  it 'rejects oversized font data before parsing it' do
    stub_const('PDFRedactor::TrueTypeProgram::MAX_BYTES', 16)
    expect { program(cmap_six(65, [7])) }.to raise_error(/byte limit/)
  end

  describe 'the PDF font fallback' do
    def pdf_font(data)
      doc = double('font document')
      allow(doc).to receive(:name) { |value| value }
      allow(doc).to receive(:resolve) { |value| value }
      allow(doc).to receive(:stream_data) do |value|
        value == :program ? data : nil
      end
      PDFRedactor::Font.new(doc,
                           'Subtype' => 'TrueType',
                           'BaseFont' => 'FixtureSymbol',
                           'FontDescriptor' => { 'FontFile2' => :program,
                                                 'Flags' => 4 })
    end

    let(:font_bytes) do
      true_type_font([1, 0, cmap_zero(65 => 7)],
                     [3, 1, cmap_six(0x03BB, [7])])
    end

    it 'uses an ordinary embedded program to decode a symbol glyph' do
      expect(pdf_font(font_bytes).unicode(65)).to eq("\u03BB")
    end

    it 'propagates a budget failure on every attempt, instead of caching nil' do
      stub_const('PDFRedactor::TrueTypeProgram::MAX_WORK', 16)
      font = pdf_font(font_bytes)
      2.times do
        expect { font.unicode(65) }.
          to raise_error(PDFRedactor::Error, /work limit/)
      end
    end
  end
end
