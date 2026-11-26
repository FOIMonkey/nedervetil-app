require_relative 'spec_helper'

RSpec.describe 'PDF redactor hardening' do
  it 'rejects deeply nested operands before overflowing the Ruby stack' do
    input = ('[' * 129) + '0' + (']' * 129)
    expect { PDFRedactor::Lexer.new(input).value }.
      to raise_error(PDFRedactor::Error, /nesting limit/)
  end

  it 'limits the total number of lexer tokens' do
    stub_const('PDFRedactor::Lexer::MAX_TOKENS', 5)
    expect do
      PDFRedactor::Lexer.each_op('1 2 3 4 5 6 noop') { |*| nil }
    end.to raise_error(PDFRedactor::Error, /token limit/)
  end

  it 'caps cumulative CMap expansion' do
    stub_const('PDFRedactor::CMap::MAX_WORK', 5)
    cmap = '1 beginbfrange <00> <09> <0041> endbfrange'
    expect { PDFRedactor::CMap.new(cmap) }.
      to raise_error(PDFRedactor::Error, /CMap work limit/)
  end

  # Counting from a one-byte destination can pass through U+D800 to U+DFFF,
  # which are not characters.
  it 'maps no code to a surrogate when a bfrange counts through them' do
    cmap = PDFRedactor::CMap.new('1 beginbfrange <0000> <FFFF> <00> endbfrange')
    mapped = ->(code) { cmap.unicode[PDFRedactor::CMap.key(2, code)] }

    expect(mapped.call(0x41)).to eq('A')
    expect(mapped.call(0xD800)).to be_nil
    expect(mapped.call(0xDFFF)).to be_nil
    expect(mapped.call(0xE000)).to eq("\uE000")
  end

  it 'stops compressed streams from expanding past the decoded limit' do
    stub_const('PDFRedactor::QdfDoc::MAX_DECODED_STREAM_BYTES', 512)
    compressed = Zlib::Deflate.deflate('A' * 1024)
    expect do
      PDFRedactor::QdfDoc.allocate.send(:inflate_bounded, compressed)
    end.to raise_error(PDFRedactor::Error, /decoded stream limit/)
  end

  it 'round trips only the supported PDF rule fields' do
    rule = PDFRedactor::Rule.new(/interesting/i, true, 'interesting'.b,
                                 'interesting')
    loaded = PDFRedactor::RuleCodec.load(PDFRedactor::RuleCodec.dump([rule]))
    expect(loaded.first.re).to eq(rule.re)
    expect(loaded.first.legacy).to eq(rule.legacy)
    expect(loaded.first.text).to eq(rule.text)
    expect(loaded.first.literal).to be(true)
    expect do
      PDFRedactor::RuleCodec.load('[{"re":{"kind":"object"}}]')
    end.to raise_error(PDFRedactor::Error)
    oversized = JSON.generate(
      [{ 're' => { 'kind' => 'regexp',
                   'source' => { 'encoding' => 'UTF-8',
                                 'bytes' => ['a'].pack('m0') },
                   'options' => 2**40 },
         'literal' => false, 'legacy' => nil, 'text' => nil }]
    )
    expect { PDFRedactor::RuleCodec.load(oversized) }.
      to raise_error(PDFRedactor::Error)
    bad_re = JSON.generate(
      [{ 're' => { 'kind' => 'regexp',
                   'source' => { 'encoding' => 'UTF-8',
                                 'bytes' => ['['].pack('m0') },
                   'options' => 0 },
         'literal' => false, 'legacy' => nil, 'text' => nil }]
    )
    expect { PDFRedactor::RuleCodec.load(bad_re) }.
      to raise_error(PDFRedactor::Error)
  end

  it 'handles long digit runs and unterminated BI in the lexer' do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    token = "#{'1' * 5000}a"
    expect(PDFRedactor::Lexer.new(token).value).to eq(token)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be < 1.0

    ['BI', 'BI /W 1 ID'].each do |stream|
      expect { PDFRedactor::Lexer.each_op(stream) { |*| nil } }.
        not_to raise_error
    end

    # Unclosed literal ending in a trailing escape must not push pos past EOF.
    expect { PDFRedactor::Lexer.each_op('(unclosed\\') { |*| nil } }.
      not_to raise_error
    expect { PDFRedactor::Lexer.new('abc', 10) }.
      to raise_error(PDFRedactor::Error, /offset out of range/)
  end

  it 'ignores empty or mismatched-length CMap ranges' do
    cmap = PDFRedactor::CMap.new(
      "1 begincodespacerange <> <> <00> <FF> endcodespacerange\n" \
      "1 beginbfrange <20> <220041> <0042> endbfrange\nendcmap"
    )
    expect(cmap.ranges.size).to eq(1)
    expect(cmap.length_at('A'.b, 0)).to eq(1)
    expect(cmap.unicode).to be_empty
  end

  it 'handles malformed JPEG segments, fill bytes, and 64-bit JP2 boxes safely' do
    redactor = PDFRedactor::Redactor.allocate
    redactor.instance_variable_set(
      :@rules, [PDFRedactor::Rule.new(/Secret/i, true, nil, 'Secret')]
    )
    redactor.instance_variable_set(:@matched, Set.new)

    bad_len = "\xFF\xD8\xFF\xE1\x00\x00\x00\x00".b
    expect(redactor.send(:censor_jpeg, bad_len)).to be_nil

    fill_bytes = "\xFF\xD8\xFF\xFF\xE1\x00\x08Secret\xFF\xD9".b
    censored = redactor.send(:censor_jpeg, fill_bytes)
    expect(censored).not_to be_nil
    expect(censored).not_to include('Secret'.b)

    huge_jp2 = [1, 'xml ', 0xFEFF000000000018].pack('Na4Q>') + '<x>Secret</x>'.b
    boxes = PDFRedactor::FinalScan.allocate.send(:jp2_boxes, huge_jp2)
    expect(boxes).to eq(['<x>Secret</x>'.b])
  end

  it 'raises PDFRedactor::Error on out-of-range xref or invalid catalog' do
    expect { PDFRedactor::QdfDoc.new("startxref\n999999\n%%EOF\n") }.
      to raise_error(PDFRedactor::Error, /xref offset/)
    empty_catalog = "xref\ntrailer\n<< >>\nstartxref\n0\n"
    expect { PDFRedactor::QdfDoc.new(empty_catalog).pages }.
      to raise_error(PDFRedactor::Error, /catalog is missing/)
  end
end
