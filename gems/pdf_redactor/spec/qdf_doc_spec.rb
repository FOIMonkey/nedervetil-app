require_relative 'spec_helper'

RSpec.describe PDFRedactor::QdfDoc do
  include AttachmentFixtures

  # A file whose document information is one object with one string in it.
  let(:doc) do
    pdf = write(['<< /Type /Catalog /Pages 2 0 R >>',
                 '<< /Type /Pages /Kids [] /Count 0 >>',
                 '<< /Title (Jane Doelittle) >>'],
                root: 1, info: 3)
    described_class.new(
      PDFRedactor.qpdf(pdf, '--qdf', '--object-streams=disable').first
    )
  end
  let(:info) { doc.object(doc.trailer['Info'].num) }
  let(:title) { info[:value]['Title'].span }

  describe '#rewrite' do
    it 'removes an object over the edits inside it' do
      out = doc.rewrite([[*title, '(x)'], [*info[:dict], 'null', :removal]])

      expect(out).to include("obj\nnull")
      expect(out).not_to include('Doelittle')
    end

    it 'refuses two edits that overlap' do
      expect { doc.rewrite([[*info[:dict], '<< >>'], [*title, '(x)']]) }.
        to raise_error(PDFRedactor::Error, /two edits overlap/)
    end

    it 'refuses null over another edit unless it is a removal' do
      expect { doc.rewrite([[*info[:dict], 'null'], [*title, '(x)']]) }.
        to raise_error(PDFRedactor::Error, /two edits overlap/)
    end

    it 'writes the same file whatever order the edits came in' do
      edits = [[title[0], title[0] + 1, '(x'], [*title, 'null', :removal]]

      expect(doc.rewrite(edits)).to eq(doc.rewrite(edits.reverse))
    end
  end

  describe '#unshare_contents' do
    it 'refuses when unsharing shared streams would exceed MAX_BYTES' do
      stream_body = 'q Q ' * 100
      shared = "<< /Length #{stream_body.bytesize} >>\nstream\n" \
               "#{stream_body}\nendstream"
      pages = Array.new(10) do
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] /Contents 3 0 R >>'
      end
      kids = (4...(4 + pages.size)).map { |n| "#{n} 0 R" }.join(' ')
      pdf = write(
        ['<< /Type /Catalog /Pages 2 0 R >>',
         "<< /Type /Pages /Kids [#{kids}] /Count #{pages.size} >>",
         shared, *pages],
        root: 1, info: nil
      )
      qdf = described_class.new(
        PDFRedactor.qpdf(pdf, '--qdf', '--object-streams=disable').first
      )
      stub_const('PDFRedactor::MAX_BYTES', 2000)

      expect { qdf.unshare_contents }.
        to raise_error(PDFRedactor::Error, /unshared content limit exceeded/)
    end
  end
end
