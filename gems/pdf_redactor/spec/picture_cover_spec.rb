require_relative 'spec_helper'

RSpec.describe PDFRedactor::PictureCover do
  # A 200 x 200 point page with a 1 x 1 picture, /Im1, and optionally a
  # form XObject /Fm1 that draws it.
  def pdf(content, form: nil)
    xobjects = '/Im1 5 0 R'
    xobjects += ' /Fm1 6 0 R' if form
    objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] ' \
      "/Resources << /XObject << #{xobjects} >> >> /Contents 4 0 R >>",
      stream('', content),
      stream('/Type /XObject /Subtype /Image /Width 1 /Height 1 ' \
             '/ColorSpace /DeviceGray /BitsPerComponent 8', "\x80")
    ]
    if form
      objects << stream('/Type /XObject /Subtype /Form /BBox [0 0 200 200] ' \
                        '/Resources << /XObject << /Im1 5 0 R >> >>', form)
    end
    out = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map do |object, index|
      at = out.bytesize
      out << "#{index + 1} 0 obj\n#{object}\nendobj\n"
      at
    end
    xref = out.bytesize
    out << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.each { |at| out << format("%010d 00000 n \n", at) }
    out << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\n" \
           "startxref\n#{xref}\n%%EOF\n"
  end

  def stream(dict, data)
    "<< #{dict} /Length #{data.bytesize} >>\nstream\n#{data}\nendstream"
  end

  let(:picture) { 'q 100 0 0 100 50 50 cm /Im1 Do Q' }

  {
    'a picture alone' => ['', nil],
    'a box drawn before it, as a background' =>
      ['0 g 40 40 120 120 re f ', :before],
    'a box elsewhere on the page' => [' 0 g 160 160 20 20 re f', nil],
    'an outline round it' => [' 0 G 2 w 50 50 100 100 re S', nil],
    'a picture beside it' => [' q 40 0 0 40 155 50 cm /Im1 Do Q', nil]
  }.each do |what, (extra, where)|
    it "passes #{what}" do
      content = where == :before ? "#{extra}#{picture}" : "#{picture}#{extra}"
      expect(described_class.first_page(pdf(content))).to be_nil
    end
  end

  {
    'a black box over half of it' => " 0 g 50 50 50 100 re f",
    'another picture over part of it' => ' q 60 0 0 60 120 120 cm /Im1 Do Q',
    'a shading over the page' => ' /Sh1 sh'
  }.each do |what, extra|
    it "finds #{what}" do
      expect(described_class.first_page(pdf("#{picture}#{extra}"))).to eq(1)
    end
  end

  it 'finds a picture clipped to part of itself' do
    content = 'q 50 50 50 100 re W n 100 0 0 100 50 50 cm /Im1 Do Q'
    expect(described_class.first_page(pdf(content))).to eq(1)
  end

  it 'finds a picture running off the page' do
    content = 'q 100 0 0 100 150 150 cm /Im1 Do Q'
    expect(described_class.first_page(pdf(content))).to eq(1)
  end

  it 'follows pictures drawn inside a form XObject' do
    expect(described_class.first_page(
             pdf('/Fm1 Do 0 g 60 60 30 30 re f', form: picture)
           )).to eq(1)
    expect(described_class.first_page(pdf('/Fm1 Do', form: picture))).to be_nil
  end

  it 'ignores malformed cm, path, and rectangle operators with too few args' do
    malformed = "1 0 cm 10 m 1 2 3 l 10 20 re f #{picture}"
    expect(described_class.first_page(pdf(malformed))).to be_nil
  end
end
