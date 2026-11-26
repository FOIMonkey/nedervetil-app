require 'spec_helper'

RSpec.describe FoiAttachment, 'masking outcome' do
  let(:info_request) { FactoryBot.create(:info_request) }
  let(:name) { 'Zebracorn' }
  let(:fault) { [PDFRedactor::Error, 'two edits overlap at byte 10'] }

  before do
    FactoryBot.create(:info_request_censor_rule,
                      censorable: info_request, text: name,
                      replacement: '[hidden]', colour: 'black')
  end

  def delivered(filename, type, body)
    message = AttachmentFixtures.deliver(info_request,
                                         [[filename, type, body]])
    attachment = message.get_attachments_for_display.
                 find { |part| part.filename == filename }
    FoiAttachment.find(attachment.id)
  end

  def masked(attachment)
    Current.without_memo { attachment.mask }
    FoiAttachment.find(attachment.id)
  end

  # Masked again, as after an expiry: masked_at goes, then #mask runs.
  def masked_again(attachment)
    attachment.update_column(:masked_at, nil)
    masked(FoiAttachment.find(attachment.id))
  end

  def served(attachment) = attachment.file.download.b

  def to_gate?(attachment)
    !attachment.erased? && !attachment.masking_failed? &&
      attachment.file.attached?
  end

  def decoded(pdf)
    PDFRedactor.qpdf(pdf, '--qdf', '--object-streams=disable').first
  end

  def letter(text = "Meeting with #{name} today")
    AttachmentFixtures.pdf(
      pages: [AttachmentFixtures.letter_page(secret: text)]
    )
  end

  def a_fault_in_masking
    allow(PDFRedactor).to receive(:redact).and_raise(*fault)
  end

  describe 'a first mask' do
    it 'gives the masked file for a text file a rule matches' do
      attachment = masked(delivered('notes.txt', 'text/plain',
                                    "Notes on #{name}.\n"))

      expect(served(attachment)).to include('Notes on [hidden]')
      expect(served(attachment)).not_to include(name)
      expect(attachment.unmasked_parts).to be_empty
      expect(attachment.masking_fault).to be_nil
      expect(to_gate?(attachment)).to be(true)
    end

    it 'gives the masked file for a PDF a rule matches' do
      attachment = masked(delivered('letter.pdf', 'application/pdf', letter))

      expect(decoded(served(attachment))).not_to include(name)
      expect(attachment.unmasked_parts).to be_empty
      expect(to_gate?(attachment)).to be(true)
    end

    it 'gives a PDF that needs a password as it came, marked' do
      locked = AttachmentFixtures.encrypted_pdf(letter)
      attachment = masked(delivered('locked.pdf', 'application/pdf', locked))

      expect(served(attachment)).to eq(locked)
      expect(attachment.unmasked_parts).
        to eq([AlaveteliTextMasker::UNMASKED_PDF])
      expect(attachment.masking_fault).to be_nil
      expect(to_gate?(attachment)).to be(true)
    end

    it 'gives the masked file for a PDF with an attached file it can’t ' \
       'read, that file as it came, marked' do
      odd = "PK\x03\x04\x00\x00#{name}".b
      content = "BT /F1 12 Tf 72 700 Td (Meeting with #{name}) Tj ET"
      pdf = AttachmentFixtures.write(
        ['<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles ' \
         '<< /Names [(a.zip) << /Type /Filespec /F (a.zip) ' \
         '/EF << /F 5 0 R >> >>] >> >> >>',
         '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
         '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
         '/Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>',
         "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream",
         "<< /Type /EmbeddedFile /Length #{odd.bytesize} >>\nstream\n".b +
           odd + "\nendstream".b,
         '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'],
        root: 1, info: nil
      )
      attachment = masked(delivered('pack.pdf', 'application/pdf', pdf))

      expect(decoded(served(attachment))).to include(odd)
      expect(decoded(served(attachment))).not_to include('Meeting with Z')
      expect(attachment.unmasked_parts).
        to match([/\Aattached file \(object \d+\) is not a PDF or UTF-8/])
      expect(to_gate?(attachment)).to be(true)
    end

    docx = 'application/vnd.openxmlformats-officedocument.' \
           'wordprocessingml.document'
    {
      'an Office document' => ['notes.docx', docx, 'lorem.docx'],
      'a plain zip' => ['notes.zip', 'application/zip', nil]
    }.each do |what, (filename, type, fixture)|
      it "gives #{what} as it came, marked" do
        body = fixture ? load_file_fixture(fixture) : "PK\x03\x04#{name}".b
        attachment = masked(delivered(filename, type, body))

        expect(served(attachment)).to eq(body.b)
        expect(attachment.unmasked_parts).
          to eq([AlaveteliTextMasker::UNMASKED_ZIP])
        expect(to_gate?(attachment)).to be(true)
      end
    end

    it 'gives an image as it came, unmarked, as images are never masked' do
      png = load_file_fixture('parrot.png')
      attachment = masked(delivered('parrot.png', 'image/png', png))

      expect(served(attachment)).to eq(png.b)
      expect(attachment.unmasked_parts).to be_empty
      expect(attachment.masking_fault).to be_nil
      expect(to_gate?(attachment)).to be(true)
    end

    it 'gives a PDF masking hits a fault on as it came, marked, and keeps ' \
       'it from going public' do
      pdf = letter
      a_fault_in_masking
      attachment = masked(delivered('letter.pdf', 'application/pdf', pdf))

      expect(served(attachment)).to eq(pdf)
      expect(attachment).to be_masking_failed
      expect(attachment.masking_fault).to eq(
        [:as_it_came, 'AlaveteliTextMasker::PDFMaskingError: ' \
                      'PDFRedactor::Error: two edits overlap at byte 10']
      )
      expect(to_gate?(attachment)).to be(false)
    end

    it 'gives a PDF as it came, marked with why, when the sandbox refuses ' \
       'the worker' do
      pdf = letter
      attachment = delivered('letter.pdf', 'application/pdf', pdf)
      allow(PDFRedactor).to receive(:isolated?).and_return(true)
      allow(AlaveteliSandbox).to receive(:job).
        and_raise(AlaveteliSandbox::Refused, 'pdf-redactor: disabled')
      attachment = masked(attachment)

      expect(served(attachment)).to eq(pdf)
      expect(attachment).to be_masking_failed
      expect(attachment.masking_fault.first).to eq(:as_it_came)
      expect(attachment.masking_fault.last).
        to include('Refused: pdf-redactor: disabled')
      expect(to_gate?(attachment)).to be(false)
    end

    it 'gives a text file whose rule times out as it came, marked, and ' \
       'keeps it from going public' do
      attachment = delivered('notes.txt', 'text/plain', "Notes on #{name}.\n")
      allow(attachment).to receive(:apply_censor_rules).
        and_raise(Regexp::TimeoutError)
      attachment = masked(attachment)

      expect(served(attachment)).to include("Notes on #{name}")
      expect(attachment.masking_fault&.first).to eq(:as_it_came)
      expect(to_gate?(attachment)).to be(false)
    end

    # A Unicode property such as \p{L} compiles for text and not for bytes.
    context 'with a rule that only reads text' do
      let!(:text_only) do
        FactoryBot.create(:info_request_censor_rule,
                          censorable: info_request, regexp: true,
                          text: '\p{L}+shire', replacement: '[place]',
                          colour: 'black')
      end

      it 'gives the masked file for a PDF, as the rule reads its text' do
        pdf = letter("Meeting with #{name} in Lakeshire today")
        attachment = masked(delivered('letter.pdf', 'application/pdf', pdf))

        expect(attachment.masking_fault).to be_nil
        expect(decoded(served(attachment))).not_to include('Lakeshire')
        expect(decoded(served(attachment))).not_to include(name)
        expect(attachment.unmasked_parts).to be_empty
        expect(to_gate?(attachment)).to be(true)
      end

      it 'gives a Word 97 file masked by its other rules, marked with the ' \
         'rule' do
        doc = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1 #{name} in Lakeshire".b
        attachment = masked(delivered('notes.doc', 'application/msword', doc))

        expect(served(attachment)).to end_with(' xxxxxxxxx in Lakeshire'.b)
        expect(attachment.unmasked_parts).
          to contain_exactly(including("censor rule #{text_only.id} "))
        expect(attachment.unmasked_parts.join).not_to include('shire')
        expect(attachment.masking_fault).to be_nil
        expect(to_gate?(attachment)).to be(true)
      end
    end

    # A \u escape for a character outside ASCII compiles from bytes, but as a
    # UTF-8 pattern, and matching that against bytes outside ASCII raises.
    context 'with a rule that only reads text, as it escapes a character' do
      let!(:text_only) do
        FactoryBot.create(:info_request_censor_rule,
                          censorable: info_request, regexp: true,
                          text: 'caf\u00e9', replacement: '[place]',
                          colour: 'black')
      end

      before { expect(text_only.reload.text).to be_ascii_only }

      # The first line has no match, so it stays as written: a byte outside
      # ASCII in the content stream the byte pass reads.
      it 'gives the masked file for a PDF, as the rule reads its text' do
        content = "BT /F1 12 Tf 72 700 Td (A na\xEFve meeting) Tj 0 -14 Td " \
                  "(with #{name} in the caf\xE9) Tj ET".b
        pdf = AttachmentFixtures.write(
          ['<< /Type /Catalog /Pages 2 0 R >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
           '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
           "<< /Length #{content.bytesize} >>\nstream\n".b + content +
             "\nendstream".b,
           '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' \
           '/Encoding /WinAnsiEncoding >>'],
          root: 1, info: nil
        )
        attachment = masked(delivered('letter.pdf', 'application/pdf', pdf))

        expect(attachment.masking_fault).to be_nil
        expect(decoded(served(attachment))).to include("na\xEFve".b)
        expect(decoded(served(attachment))).not_to include("caf\xE9".b)
        expect(decoded(served(attachment))).not_to include(name)
        expect(attachment.unmasked_parts).to be_empty
        expect(to_gate?(attachment)).to be(true)
      end

      it 'gives a Word 97 file masked by its other rules, marked with the ' \
         'rule' do
        doc = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1 #{name} in the café".b
        attachment = masked(delivered('notes.doc', 'application/msword', doc))

        expect(served(attachment)).to end_with(' xxxxxxxxx in the café'.b)
        expect(attachment.unmasked_parts).
          to contain_exactly(including("censor rule #{text_only.id} "))
        expect(attachment.masking_fault).to be_nil
        expect(to_gate?(attachment)).to be(true)
      end
    end
  end

  describe 'masking again after a fault' do
    it 'gives the masked file, and lets it go public, once masking works ' \
       'again after a fault' do
      a_fault_in_masking
      first = masked(delivered('letter.pdf', 'application/pdf', letter))
      expect(first).to be_masking_failed
      allow(PDFRedactor).to receive(:redact).and_call_original
      attachment = masked_again(first)

      expect(decoded(served(attachment))).not_to include(name)
      expect(attachment).not_to be_masking_failed
      expect(attachment.masking_fault).to be_nil
      expect(to_gate?(attachment)).to be(true)
    end
  end
end
