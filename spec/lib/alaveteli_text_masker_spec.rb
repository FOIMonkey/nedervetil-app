require 'spec_helper'

RSpec.describe AlaveteliTextMasker do
  let(:class_instance) { Class.new { include AlaveteliTextMasker }.new }

  describe '.apply_masks caller contract' do
    it 'accepts a missing body without invoking the PDF redactor' do
      expect(PDFRedactor).not_to receive(:redact)
      expect(described_class.apply_masks(nil, 'application/pdf')).to be_nil
    end

    %w[
      image/tiff image/gif image/jpeg image/png image/bmp application/zip
      application/vnd.openxmlformats-officedocument.wordprocessingml.document
      application/vnd.openxmlformats-officedocument.wordprocessingml.template
      application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
      application/vnd.openxmlformats-officedocument.spreadsheetml.template
      application/vnd.openxmlformats-officedocument.presentationml.presentation
      application/vnd.openxmlformats-officedocument.presentationml.slideshow
      application/vnd.openxmlformats-officedocument.presentationml.template
      application/vnd.ms-word.document.macroenabled.12
      application/vnd.ms-word.template.macroenabled.12
      application/vnd.ms-excel.sheet.macroenabled.12
      application/vnd.ms-excel.sheet.binary.macroenabled.12
      application/vnd.ms-excel.template.macroenabled.12
      application/vnd.ms-excel.sheet.macroEnabled.12
      application/vnd.ms-powerpoint.presentation.macroenabled.12
      application/vnd.ms-powerpoint.slideshow.macroenabled.12
      application/vnd.oasis.opendocument.text
      application/vnd.oasis.opendocument.text-template
      application/vnd.oasis.opendocument.spreadsheet
      application/vnd.oasis.opendocument.presentation
      application/vnd.oasis.opendocument.graphics
      application/vnd.sun.xml.writer
      application/vnd.sun.xml.calc
      application/vnd.sun.xml.impress
    ].each do |content_type|
      it "preserves #{content_type} bytes even with censor rules" do
        body = "\xFFprivate@example.test\x00".b.freeze
        rule = FactoryBot.build(:censor_rule, text: 'private')

        expect(described_class.apply_masks(body, content_type,
                                           censor_rules: [rule])).to equal(body)
      end
    end

    it 'preserves a mislabelled zip container by its magic bytes' do
      body = "PK\x03\x04private@example.test".b.freeze
      rule = FactoryBot.build(:censor_rule, text: 'private')

      expect(described_class.apply_masks(body, 'application/octet-stream',
                                         censor_rules: [rule])).to equal(body)
    end

    it 'records that a zip container goes out as it came' do
      unmasked = []
      docx = 'application/vnd.openxmlformats-officedocument' \
             '.wordprocessingml.document'

      described_class.apply_masks("PK\x03\x04data".b, docx, unmasked: unmasked)

      expect(unmasked).to eq([AlaveteliTextMasker::UNMASKED_ZIP])
    end

    {
      '7-Zip' => "7z\xBC\xAF\x27\x1C\x00\x04private@example.test".b,
      'RAR' => "Rar!\x1A\x07\x00private@example.test".b,
      'gzip' => "\x1F\x8B\x08\x00\x00\x00\x00\x00\x00\x03private@x.test".b
    }.each do |what, body|
      it "serves #{what} as it came, and records that" do
        unmasked = []
        result = described_class.apply_masks(body, 'application/octet-stream',
                                             unmasked: unmasked)
        expect(result).to equal(body)
        expect(unmasked).to eq([AlaveteliTextMasker::UNMASKED_ZIP])
      end
    end

    it 'still byte-masks an OLE file, unmarked' do
      body = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1 private@example.test".b
      unmasked = []
      result = described_class.apply_masks(body, 'application/x-unknown',
                                           unmasked: unmasked)
      expect(result).not_to include('private@example.test')
      expect(unmasked).to be_empty
    end

    # A Unicode property such as \p{L} compiles for text and not for bytes.
    it 'skips a rule the byte pass can’t use, applies the rest, and ' \
       'records the rule by its id' do
      text_only = FactoryBot.create(:global_censor_rule, regexp: true,
                                                         text: '\p{L}+shire')
      other = FactoryBot.build(:censor_rule, text: 'Zebracorn')
      unmasked = []
      result = described_class.apply_masks(
        'Zebracorn of Lakeshire'.b, 'application/vnd.ms-word',
        censor_rules: [text_only, other], unmasked: unmasked
      )

      expect(result).to eq('xxxxxxxxx of Lakeshire'.b)
      expect(unmasked).
        to contain_exactly(including("censor rule #{text_only.id} "))
      expect(unmasked.join).not_to include('shire')
    end

    it 'records nothing for an image, which is never masked' do
      unmasked = []
      described_class.apply_masks("\xFF\xD8\xFF".b, 'image/jpeg',
                                  unmasked: unmasked)
      expect(unmasked).to be_empty
    end

    it 'logs that censor rules cannot reach an archive' do
      body = "\xFFprivate@example.test\x00".b.freeze
      rule = FactoryBot.build(:censor_rule, text: 'private')
      docx = 'application/vnd.openxmlformats-officedocument' \
             '.wordprocessingml.document'
      expect(Rails.logger).to receive(:info).with(/an archive/)

      described_class.apply_masks(body, docx, censor_rules: [rule])
    end

    # OLE binary formats and uncompressed -flat-xml stay on the byte pass;
    # MailHandler.normalise_content_type maps .doc files to vnd.ms-word.
    %w[application/vnd.ms-word application/vnd.ms-excel
       application/vnd.ms-powerpoint
       application/vnd.oasis.opendocument.text-flat-xml].each do |content_type|
      it "still byte-masks #{content_type} in place" do
        body = "\xFFprivate@example.test\x00".b.freeze
        result = described_class.apply_masks(body, content_type)

        expect(result).to eq("\xFFxxxxxxx@xxxxxxx.xxxx\x00".b)
        expect(result.bytesize).to eq(body.bytesize)
        expect(body).to include('private@example.test')
      end
    end

    it 'leaves out the default masks when asked, keeping the censor rules' do
      rule = FactoryBot.build(:censor_rule, text: 'private', replacement: 'x')
      options = { censor_rules: [rule], default_masks: false }

      expect(described_class.apply_masks('private a@example.test',
                                         'text/plain', options)).
        to eq('x a@example.test')
      expect(described_class.apply_masks("\xFFa@example.test\x00".b,
                                         'application/x-unknown', options)).
        to eq("\xFFa@example.test\x00".b)
    end

    it 'masks unknown binary types without changing input or byte length' do
      body = "\xFFprivate@example.test\x00".b.freeze
      result = described_class.apply_masks(body, 'application/x-unknown')

      expect(result).to eq("\xFFxxxxxxx@xxxxxxx.xxxx\x00".b)
      expect(result.bytesize).to eq(body.bytesize)
      expect(body).to include('private@example.test')
    end

    it 'prefers extra text masks on ties and does not double-redact replacements' do
      body = 'Stilton private@example.test'.freeze
      non_matching = FactoryBot.build(:censor_rule, text: 'blue',
                                                    replacement: 'yellow')
      same_span = FactoryBot.build(:censor_rule, text: 'Stilton',
                                                 replacement: 'cheddar')
      result = described_class.apply_masks(
        body, 'text/plain',
        censor_rules: [non_matching, same_span],
        masks: [{ to_replace: 'Stilton', replacement: 'blue' }]
      )

      expect(result).to eq('blue [email address]')
      expect(body).to eq('Stilton private@example.test')
    end

    describe 'simultaneous span-merging in TextPass' do
      it 'hides the full name for Example + Jane Example in either order' do
        short = FactoryBot.build(:censor_rule, text: 'Example',
                                               replacement: '[surname]')
        full = FactoryBot.build(:censor_rule, text: 'Jane Example',
                                              replacement: '[full name]')
        text = 'Signed by Jane Example yesterday.'

        matched_a = []
        result_a = described_class.apply_masks(
          text, 'text/plain',
          censor_rules: [short, full], default_masks: false, matched: matched_a
        )
        expect(result_a).to eq('Signed by [full name] yesterday.')
        expect(matched_a).to contain_exactly(short, full)

        matched_b = []
        result_b = described_class.apply_masks(
          text, 'text/plain',
          censor_rules: [full, short], default_masks: false, matched: matched_b
        )
        expect(result_b).to eq('Signed by [full name] yesterday.')
        expect(matched_b).to contain_exactly(full, short)
      end

      it 'merges overlapping phrases and breaks exact-length ties by priority' do
        first = FactoryBot.build(:censor_rule, text: 'Alice Baker',
                                               replacement: '[first]')
        second = FactoryBot.build(:censor_rule, text: 'Baker Jones',
                                                replacement: '[second]')
        longer = FactoryBot.build(:censor_rule, text: 'Baker Jones Senior',
                                                replacement: '[longer]')

        expect(
          described_class.apply_masks(
            'Met Alice Baker Jones today.', 'text/plain',
            censor_rules: [first, second], default_masks: false
          )
        ).to eq('Met [first] today.')

        expect(
          described_class.apply_masks(
            'Met Alice Baker Jones Senior today.', 'text/plain',
            censor_rules: [first, longer], default_masks: false
          )
        ).to eq('Met [longer] today.')

        expect(
          described_class.apply_masks(
            'Contact test@example.com now.', 'text/plain',
            censor_rules: [
              FactoryBot.build(:censor_rule, text: 'test@example.com',
                                             replacement: '[rule]')
            ]
          )
        ).to eq('Contact [rule] now.')
      end

      it 'never double-redacts another rule’s replacement text' do
        full = FactoryBot.build(:censor_rule, text: 'Jane Example',
                                              replacement: '[name removed]')
        word = FactoryBot.build(:censor_rule, text: 'name',
                                              replacement: '[REDACTED]')

        result = described_class.apply_masks(
          'Dear Jane Example, thank you.', 'text/plain',
          censor_rules: [full, word], default_masks: false
        )
        expect(result).to eq('Dear [name removed], thank you.')
      end

      it 'evaluates regexp backreferences per match' do
        rule = FactoryBot.build(:regexp_censor_rule,
                                text: '(Dear) Jane Example',
                                replacement: '\1 [redacted]')

        result = described_class.apply_masks(
          'Dear Jane Example, hello.', 'text/plain',
          censor_rules: [rule], default_masks: false
        )
        expect(result).to eq('Dear [redacted], hello.')
      end

      it 'masks matches that come after accented and non-Latin text' do
        text = 'Renée 李明 wrote to Zoë Example at test@example.com. ' \
               'ZOË EXAMPLE replied to Zoë Example — über.'
        masked = 'Renée 李明 wrote to [name] at [email address]. ' \
                 'ZOË EXAMPLE replied to [name] — über.'
        plain = FactoryBot.build(:censor_rule, text: 'Zoë Example',
                                               replacement: '[name]')
        any_case = FactoryBot.build(:censor_rule, :case_insensitive,
                                    text: 'zoë example',
                                    replacement: '[name]')

        expect(
          described_class.apply_masks(text, 'text/plain',
                                      censor_rules: [plain])
        ).to eq(masked)
        expect(
          described_class.apply_masks(text, 'text/plain',
                                      censor_rules: [any_case])
        ).to eq(masked.sub('ZOË EXAMPLE', '[name]'))
      end

      # 李明华 is three characters in nine bytes; 华 Wang is six in eight.
      it 'takes the longest overlapping match by characters, not bytes' do
        first = FactoryBot.build(:censor_rule, text: '李明华',
                                               replacement: '[first]')
        second = FactoryBot.build(:censor_rule, text: '华 Wang',
                                                replacement: '[second]')

        expect(
          described_class.apply_masks(
            'Met 李明华 Wang today.', 'text/plain',
            censor_rules: [first, second], default_masks: false
          )
        ).to eq('Met [second] today.')
      end

      it 'applies a plain rule to text with bytes that are not valid' do
        rule = FactoryBot.build(:censor_rule, text: 'Zoë Example',
                                              replacement: '[name]')
        text = "Caf\xE9 notes: Zoë Example\x92s, Zoë Example".
          dup.force_encoding('UTF-8')
        masked = "Caf\xE9 notes: [name]\x92s, [name]".
          dup.force_encoding('UTF-8')

        expect(
          described_class.apply_masks(text, 'text/plain',
                                      censor_rules: [rule],
                                      default_masks: false)
        ).to eq(masked)
      end
    end

    it 'leaves a blank text mask out' do
      result = described_class.apply_masks(
        'Stilton', 'text/plain',
        masks: [{ to_replace: '', replacement: '[nothing]' },
                { to_replace: nil, replacement: '[nothing]' }]
      )

      expect(result).to eq('Stilton')
    end

    it 'records each PDF rule match against the caller supplied attribute' do
      rules = %w[absent present].map do |text|
        FactoryBot.build(:censor_rule, text: text)
      end
      record = double('redactable')
      report = { 'rules_matched' => [1], 'changed' => true }
      allow(PDFRedactor).to receive(:redact).
        and_return(['masked bytes', report])
      expect(rules[0]).to receive(:record_match).
        with(record, :body, matched: false)
      expect(rules[1]).to receive(:record_match).
        with(record, :body, matched: true)

      result = described_class.apply_masks(
        'original bytes', 'application/pdf',
        censor_rules: rules,
        redactable: record, redacted_attribute: :body
      )

      expect(result).to eq('masked bytes')
    end

    it 'preserves regexp timeout errors for the attachment failure handler' do
      allow(PDFRedactor).to receive(:redact).
        and_raise(Regexp::TimeoutError, 'pattern too slow')

      expect { described_class.apply_masks('bytes', 'application/pdf') }.
        to raise_error(Regexp::TimeoutError, 'pattern too slow')
    end
  end

  describe '#apply_masks' do
    context 'applying censor rules' do
      before do
        @cheese_censor_rule = FactoryBot.build(:censor_rule,
                                               text: 'Stilton',
                                               replacement: 'Jarlsberg')
        @colour_censor_rule = FactoryBot.build(:censor_rule,
                                               text: 'blue',
                                               replacement: 'yellow')
        @regex_censor_rule = FactoryBot.build(:censor_rule,
                                              text: 'm[a-z][a-z][a-z]e',
                                              replacement: 'cat',
                                              regexp: true)
        @censor_rules = [@cheese_censor_rule,
                         @colour_censor_rule,
                         @regex_censor_rule]
      end

      it "does nothing to a JPEG" do
        data = "There was a mouse called Stilton, he wished that he was blue."

        result = class_instance.apply_masks(data,
                                            "image/jpeg",
                                            censor_rules: @censor_rules)

        expect(result).
          to eq("There was a mouse called Stilton, he wished that he was blue.")
      end

      it "replaces censor text in Word documents" do
        data = "There was a mouse called Stilton, he wished that he was blue."
        result = class_instance.apply_masks(data,
                                            "application/vnd.ms-word",
                                            censor_rules: @censor_rules)
        expect(result).
          to eq("There was a xxxxx called xxxxxxx, he wished that he was xxxx.")
      end

      it 'handles multibyte characters in binary file types as binary data' do
        data = 'á mouse'.force_encoding("ASCII-8BIT")
        @regex_censor_rule.text = 'á'
        result = class_instance.apply_masks(data,
                                            "application/octet-stream",
                                            censor_rules: @censor_rules)
        expect(result).to eq('xx mouse')
      end

      it "applies censor rules to HTML files" do
        data = "There was a mouse called Stilton, he wished that he was blue."
        result = class_instance.apply_masks(data,
                                            'text/html',
                                            censor_rules: @censor_rules)
        expect(result).
          to eq("There was a cat called Jarlsberg, " \
                "he wished that he was yellow.")
      end
    end

    context 'redaction tracking via redactable: option', feature: :redaction_tracking do
      let(:rule) { FactoryBot.create(:global_censor_rule, text: 'Stilton') }
      let(:redactable) { FactoryBot.create(:info_request) }

      it 'records a redaction on the redactable when a censor rule matches' do
        expect {
          class_instance.apply_masks(
            'There was a mouse called Stilton.',
            'text/plain',
            censor_rules: [rule],
            redactable: redactable,
            redacted_attribute: :body
          )
        }.to change(CensorRule::Redaction, :count).by(1)
      end

      it 'does not record a redaction when redactable: is absent' do
        expect {
          class_instance.apply_masks(
            'There was a mouse called Stilton.',
            'text/plain',
            censor_rules: [rule]
          )
        }.not_to change(CensorRule::Redaction, :count)
      end

      it 'records a redaction when a censor rule matches a PDF' do
        pdf = AttachmentFixtures.pdf(
          pages: [AttachmentFixtures.letter_page(secret: 'Stilton')]
        )
        expect {
          class_instance.apply_masks(pdf, 'application/pdf',
                                     censor_rules: [rule],
                                     redactable: redactable,
                                     redacted_attribute: :body)
        }.to change(CensorRule::Redaction, :count).by(1)
      end

      it 'does not record a redaction when no rule matches' do
        expect {
          class_instance.apply_masks(
            'No match here.',
            'text/plain',
            censor_rules: [rule],
            redactable: redactable,
            redacted_attribute: :body
          )
        }.not_to change(CensorRule::Redaction, :count)
      end
    end

    context 'applying masks to binary' do
      it "replaces ASCII email addresses in Word documents" do
        data = "His email was foo@bar.com"
        result = class_instance.apply_masks(data, "application/vnd.ms-word")
        expect(result).to eq("His email was xxx@xxx.xxx")
      end

      it "replaces UCS-2 addresses in Word documents" do
        data = "His email was f\000o\000o\000@\000b\000a\000r\000." \
               "\000c\000o\000m\000, indeed"
        expected = "His email was x\000x\000x\000@\000x\000x\000x\000." \
                   "\000x\000x\000x\000, indeed"
        result = class_instance.apply_masks(data, "application/vnd.ms-word")
        expect(result).to eq(expected)
      end

      it 'replaces an ASCII address at a domain such as gov.wales' do
        result = class_instance.apply_masks('His email was jane.doe@gov.wales',
                                            'application/vnd.ms-word')
        expect(result).to eq('His email was xxxx.xxx@xxx.xxxxx')
      end

      it 'replaces a UCS-2 address at a domain such as llyw.cymru' do
        address = 'foi@llyw.cymru'.encode('UTF-16LE').b
        masked = 'xxx@xxxx.xxxxx'.encode('UTF-16LE').b
        result = class_instance.apply_masks("Hers was #{address}, indeed".b,
                                            'application/vnd.ms-word')
        expect(result).to eq("Hers was #{masked}, indeed".b)
      end

      it 'replaces both of two ASCII addresses joined by a full stop' do
        result = class_instance.apply_masks(
          'Ask jane@example.com.joanna@example.org', 'application/vnd.ms-word'
        )
        expect(result).to eq('Ask xxxx@xxxxxxx.xxx.xxxxxx@xxxxxxx.xxx')
      end

      # UCS-2 masking replaces all copies of each found address.
      it 'replaces each copy of a UCS-2 address when a word is joined to one' do
        text = 'Contact jane@example.com1 for details. Email ' \
               'jane@example.com.Otherwise call.'
        masked = 'Contact xxxx@xxxxxxx.xxx1 for details. Email ' \
                 'xxxx@xxxxxxx.xxx.Otherwise call.'
        result = class_instance.apply_masks(text.encode('UTF-16LE').b,
                                            'application/vnd.ms-word')
        expect(result).to eq(masked.encode('UTF-16LE').b)
      end

      it 'replaces each copy of a UCS-2 address when an @ follows one' do
        text = 'jane@example.com_ and jane@example.com@INTERNET.Thanks'
        masked = 'xxxx@xxxxxxx.xxx_ and xxxx@xxxxxxx.xxx@INTERNET.Thanks'
        result = class_instance.apply_masks(text.encode('UTF-16LE').b,
                                            'application/vnd.ms-word')
        expect(result).to eq(masked.encode('UTF-16LE').b)
      end

      it 'replaces UTF-8 double width characters' do
        data = 'Héllø world'
        rule = CensorRule.new(text: 'Héllø')
        result = class_instance.apply_masks(
          data, 'application/vnd.ms-word', censor_rules: [rule]
        )
        expect(result).to eq 'xxxxxxx world'
      end

      it 'finds UCS-2 addresses across NUL strip slices in large data' do
        address = 'foo@bar.com'.encode('UTF-16LE').force_encoding('BINARY')
        masked = 'xxx@xxx.xxx'.encode('UTF-16LE').force_encoding('BINARY')
        gap = ' and '.encode('UTF-16LE').force_encoding('BINARY')
        padding = "\0".b * (AlaveteliTextMasker::NUL_STRIP_SLICE - 7)
        data = padding + address + gap + padding + address
        result = class_instance.apply_masks(data, 'application/vnd.ms-word')
        expect(result).to eq(padding + masked + gap + padding + masked)
      end

      it 'finds a UCS-2 address in large data with few NUL bytes' do
        address = 'foo@bar.com'.encode('UTF-16LE').force_encoding('BINARY')
        masked = 'xxx@xxx.xxx'.encode('UTF-16LE').force_encoding('BINARY')
        filler = 'x'.b * (2 * 1024 * 1024)
        result = class_instance.apply_masks(
          "#{filler} #{address} #{filler}".b,
          'application/vnd.ms-word'
        )
        expect(result).to eq("#{filler} #{masked} #{filler}".b)
      end

      it 'strips NUL bytes from large UTF-8 text' do
        data = "Contact foo@bar.com ✓ \0".dup * 100_000
        result = class_instance.apply_masks(data, 'application/vnd.ms-word')
        expect(result).to eq("Contact xxx@xxx.xxx ✓ \0" * 100_000)
        expect(result.encoding).to eq(data.encoding)
      end
    end

    context 'applying masks to PDF' do
      include AttachmentFixtures

      def text_of(pdf)
        AttachmentToText.from_string(pdf, content_type: 'application/pdf').
          to_text
      end

      let(:letter) do
        pdf(pages: [letter_page(secret: 'Meeting with Jane Doelittle today')])
      end

      it 'covers email addresses' do
        pdf = load_file_fixture('tfl.pdf')
        expect(text_of(pdf)).to match(/foi@tfl.gov.uk/)

        result = class_instance.apply_masks(pdf, 'application/pdf')

        masked_text = text_of(result)
        expect(masked_text).not_to match(/foi@tfl.gov.uk/)
        expect(masked_text).to include('[redacted]')
      end

      it 'applies censor rules to the text of a PDF' do
        rule = FactoryBot.build(:censor_rule, text: 'Jane Doelittle')

        result = class_instance.apply_masks(letter, 'application/pdf',
                                            censor_rules: [rule])

        expect(text_of(result)).not_to include('Doelittle')
        expect(text_of(result)).to include('Meeting with')
      end

      it 'applies regexp censor rules to the text of a PDF' do
        rule = FactoryBot.build(:regexp_censor_rule, text: 'Doe\w+')

        result = class_instance.apply_masks(letter, 'application/pdf',
                                            censor_rules: [rule])

        expect(text_of(result)).not_to include('Doelittle')
      end

      it 'applies extra masks to the text of a PDF' do
        result = class_instance.apply_masks(
          letter, 'application/pdf',
          masks: [{ to_replace: 'Jane Doelittle', replacement: '[name]' }]
        )

        expect(text_of(result)).not_to include('Doelittle')
      end

      it 'does not produce zero length output' do
        pdf = load_file_fixture('psni.pdf')
        result = class_instance.apply_masks(pdf, 'application/pdf')
        expect(result).not_to eq('')
      end

      it 'writes the PDF again even if there is nothing to censor' do
        pdf = load_file_fixture('interesting.pdf')

        result = class_instance.apply_masks(pdf, 'application/pdf')

        expect(result).to start_with('%PDF')
        expect(result).not_to eq(pdf)
        expect(text_of(result)).to eq(text_of(pdf))
      end

      it 'serves a PDF that needs a password as it is, and records that' do
        locked = encrypted_pdf(letter)
        unmasked = []

        expect(class_instance.apply_masks(locked, 'application/pdf',
                                          unmasked: unmasked)).to eq(locked)
        expect(unmasked).to eq([AlaveteliTextMasker::UNMASKED_PDF])
      end

      it 'masks a PDF with an attached PDF that needs a password' do
        locked = encrypted_pdf(letter)
        attached = "<< /Type /EmbeddedFile /Length #{locked.bytesize} >>\n" \
                   "stream\n".b + locked + "\nendstream".b
        pdf = write(
          ['<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles ' \
           '<< /Names [(a.pdf) << /Type /Filespec /F (a.pdf) ' \
           '/EF << /F 4 0 R >> >>] >> >> >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>',
           attached],
          root: 1, info: nil
        )

        unmasked = []
        result = class_instance.apply_masks(pdf, 'application/pdf',
                                            unmasked: unmasked)

        expect(result).to start_with('%PDF')
        expect(result).not_to eq(pdf)
        expect(unmasked).
          to match([/\Aattached PDF \(object \d+\) needs a password\z/])
      end

      it 'keeps a PDF masked before as it is if no rule changes it' do
        masked = class_instance.apply_masks(letter, 'application/pdf')
        expect(
          class_instance.apply_masks(masked, 'application/pdf', masked: true)
        ).to eq(masked)
      end

      it 'masks a PDF masked before again if a rule changes it' do
        masked = class_instance.apply_masks(letter, 'application/pdf')
        rule = FactoryBot.build(:censor_rule, text: 'Jane Doelittle')

        again = class_instance.apply_masks(masked, 'application/pdf',
                                           masked: true, censor_rules: [rule])

        expect(text_of(again)).not_to include('Doelittle')
      end

      it 'raises PDFMaskingError if the PDF cannot be read' do
        allow(Rails.logger).to receive(:warn)
        expect { class_instance.apply_masks('not a PDF', 'application/pdf') }.
          to raise_error(AlaveteliTextMasker::PDFMaskingError)
        expect(Rails.logger).
          to have_received(:warn).with(/\[masking\] PDF not masked/)
      end

      it 'raises PDFMaskingError if the sandbox refuses qpdf' do
        allow(AlaveteliSandbox).
          to receive(:job).and_raise(AlaveteliSandbox::Refused, 'disabled')
        expect { class_instance.apply_masks(letter, 'application/pdf') }.
          to raise_error(AlaveteliTextMasker::PDFMaskingError, /disabled/)
      end

      it 'raises PDFMaskingError if OCR cannot read a scanned page' do
        scan = Dir.mktmpdir do |dir|
          File.binwrite("#{dir}/page.pdf", letter)
          png = render_pages("#{dir}/page.pdf", dir, dpi: 72).first
          magick(png, "#{dir}/scan.pdf")
          File.binread("#{dir}/scan.pdf")
        end
        allow(PDFRedactor::Ocr).to receive(:available?).and_return(true)
        allow(PDFRedactor::Ocr).to receive(:read_pages).and_return([nil])

        expect do
          class_instance.apply_masks(
            scan, 'application/pdf',
            censor_rules: [FactoryBot.build(:info_request_censor_rule)]
          )
        end.to raise_error(AlaveteliTextMasker::PDFMaskingError,
                           /OCR could not/)
      end

      describe 'reading scanned pages' do
        def ocr_for(*rules)
          ocr = nil
          allow(PDFRedactor).to receive(:redact) do |*, **options|
            ocr = options[:ocr]
            [letter, { 'rules_matched' => [] }]
          end
          class_instance.apply_masks(letter, 'application/pdf',
                                     censor_rules: rules)
          ocr
        end

        it 'reads them for a rule on the request' do
          expect(ocr_for(FactoryBot.build(:info_request_censor_rule))).
            to be(true)
        end

        it 'reads them for a rule on the user' do
          expect(ocr_for(FactoryBot.build(:user_censor_rule))).to be(true)
        end

        it 'does not read them for global or public body rules' do
          expect(ocr_for(FactoryBot.build(:global_censor_rule),
                         FactoryBot.build(:public_body_censor_rule))).
            to be(false)
        end

        it 'does not read them for the default masks alone' do
          expect(ocr_for).to be(false)
        end
      end
    end

    context 'applying masks to text' do
      it "applies hard-coded privacy rules to HTML files" do
        data = "http://test.host/c/cheese"
        result = class_instance.apply_masks(data, 'text/html')
        expect(result).to eq("[Alaveteli login link]")
      end

      it 'replaces a simple email address' do
        data = "the address is test@example.com"
        expected = "the address is [email address]"
        result = class_instance.apply_masks(data, 'text/html', {})
        expect(result).to eq(expected)
      end

      %w[foi@tfl.gov.uk x@met.police.uk y@nhs.scot jane.doe@gov.wales
         w@senedd.wales foi@llyw.cymru x@barnet.london
         z@example.museum].each do |address|
        it "replaces #{address}, and keeps the full stop after it" do
          result = class_instance.apply_masks("Write to #{address}. Then call.",
                                              'text/plain')
          expect(result).to eq('Write to [email address]. Then call.')
        end
      end

      %w[JANE.DOE@GOV.WALES svc@mailhost.council.local].each do |address|
        it "replaces #{address}" do
          result = class_instance.apply_masks("Write to #{address} today",
                                              'text/plain')
          expect(result).to eq('Write to [email address] today')
        end
      end

      it 'leaves a longer word joined to an address by a full stop' do
        data = 'mail jo@example.org.Otherwise write, jo@example.org.' \
               'otherwise call, or jane.doe@gov.wales.Please ask'
        result = class_instance.apply_masks(data, 'text/plain')
        expect(result).to eq('mail [email address].Otherwise write, ' \
                             '[email address].otherwise call, or ' \
                             '[email address].Please ask')
      end

      %w[jane@example.com.joanna@example.org
         jane@example.com.joanna@example.org.richard@example.net
         jane.doe@gov.wales.joanna@llyw.cymru].
        each do |joined|
        it "leaves nothing of #{joined}, addresses joined by full stops" do
          result = class_instance.apply_masks("mail #{joined} now",
                                              'text/plain')
          expect(result).to match(/\Amail (\[email address\])+ now\z/)
        end
      end

      it 'still replaces an address that an @ follows straight away' do
        result = class_instance.apply_masks(
          'from jane@example.com@INTERNET today', 'text/plain'
        )
        expect(result).to eq('from [email address]@INTERNET today')
      end

      it 'finds addresses in time that grows no faster than the text' do
        expect(Regexp.linear_time?(MySociety::Validate.email_find_regexp)).
          to be(true)
      end

      describe 'what follows an address' do
        it 'is still masked when it is a mobile number after a full stop' do
          result = class_instance.apply_masks(
            'Email: jane.doe@council.gov.uk.Mobile: 07700 900123', 'text/plain'
          )
          expect(result).to eq('Email: [email address].[mobile number]')
        end

        it 'is still masked when it is a mobile number run on to it' do
          result = class_instance.apply_masks(
            'Email: jane.doe@council.gov.ukMobile: 07700 900123', 'text/plain'
          )
          expect(result).to include('[mobile number]')
          expect(result).not_to include('07700')
        end

        it 'is still masked when it is a login link after a full stop' do
          result = class_instance.apply_masks(
            'Sign in: jane@example.com.https://test.host/c/abcdef123456 now',
            'text/plain'
          )
          expect(result).
            to eq('Sign in: [email address].[Alaveteli login link] now')
        end

        it 'still gets a censor rule when it is a name after a full stop' do
          rule = FactoryBot.build(:censor_rule, text: 'Officer Example',
                                                replacement: '[name removed]')
          result = class_instance.apply_masks(
            'Reply to foi@council.gov.uk.Officer Example will answer.',
            'text/plain', censor_rules: [rule]
          )
          expect(result).
            to eq('Reply to [email address].[name removed] will answer.')
        end

        it 'is still masked after an address at a domain such as gov.wales' do
          result = class_instance.apply_masks(
            'jane.doe@gov.wales.Mobile: 07700 900123 or foi@llyw.cymru.' \
            'https://test.host/c/abcdef123456', 'text/plain'
          )
          expect(result).to eq('[email address].[mobile number] or ' \
                               '[email address].[Alaveteli login link]')
        end
      end

      it 'replaces a mobile phone number prefixed with "Mobile"' do
        data = "the mobile is Mobile 55555 555555"
        expected = "the mobile is [mobile number]"
        result = class_instance.apply_masks(data, 'text/html', {})
        expect(result).to eq(expected)
      end

      it 'replaces a mobile phone number prefixed with "Mob Tel"' do
        data = "the mobile is Mob Tel: 55555 555 555"
        expected = "the mobile is [mobile number]"
        result = class_instance.apply_masks(data, 'text/html', {})
        expect(result).to eq(expected)
      end

      it 'replaces a mobile phone number prefixed with "Mob/Fax:"' do
        data = "the mobile is Mob/Fax: 55555 555555"
        expected = "the mobile is [mobile number]"
        result = class_instance.apply_masks(data, 'text/html', {})
        expect(result).to eq(expected)
      end

      it "replaces an Alaveteli login link" do
        data = "the login link is http://test.host/c/ekfmsdfkm"
        expected = "the login link is [Alaveteli login link]"
        result = class_instance.apply_masks(data, 'text/html', {})
        expect(result).to eq(expected)
      end

      it "replaces a https Alaveteli login link" do
        data = "the login link is https://test.host/c/ekfmsdfkm"
        expected = "the login link is [Alaveteli login link]"
        result = class_instance.apply_masks(data, 'text/html', {})
        expect(result).to eq(expected)
      end

      it "applies censor rules to text" do
        data = "here is a mouse"
        expected = "here is a cat"

        censor_rule = FactoryBot.build(:censor_rule,
                                       text: 'mouse',
                                       replacement: 'cat')

        result = class_instance.apply_masks(data,
                                            'text/html',
                                            censor_rules: [censor_rule])
        expect(result).to eq(expected)
      end

      it 'applies extra masks to text' do
        data = "here is a mouse"
        expected = "here is a cat"
        mask = { to_replace: 'mouse', replacement: 'cat' }
        result = class_instance.apply_masks(data, 'text/html', masks: [mask])
        expect(result).to eq(expected)
      end
    end
  end

  describe '.masks' do
    after { described_class.reset_masks! }

    it 'returns the three built-in masks' do
      expect(described_class.masks.keys).
        to eq(%i[email_address mobile_number login_link])
    end
  end

  describe '.add_mask' do
    after { described_class.reset_masks! }

    it 'appends a new mask' do
      described_class.add_mask(:reference, pattern: /\d/, replacement: '[ref]')
      expect(described_class.masks.keys.last).to eq(:reference)
    end

    it 'raises ArgumentError when a mask with the same name already exists' do
      expect {
        described_class.
          add_mask(:email_address, pattern: /.@./, replacement: '[x]')
      }.to raise_error(ArgumentError, /email_address/)
    end
  end

  describe '.remove_mask' do
    after { described_class.reset_masks! }

    it 'removes a built-in mask so it is no longer applied' do
      described_class.remove_mask(:mobile_number)
      expect(described_class.masks.keys).to eq(%i[email_address login_link])
    end

    it 'raises ArgumentError when the name does not exist' do
      expect { described_class.remove_mask(:nonexistent) }.
        to raise_error(ArgumentError, /nonexistent/)
    end
  end

  describe '.replace_mask' do
    after { described_class.reset_masks! }

    it 'replaces the pattern but keeps the existing replacement' do
      original_replacement = described_class.masks[:mobile_number][:replacement]

      described_class.replace_mask(:mobile_number, pattern: /Cell \d+/)

      mobile_number = described_class.masks[:mobile_number]
      expect(mobile_number[:to_replace]).to eq(/Cell \d+/)
      expect(mobile_number[:replacement]).to eq(original_replacement)
    end

    it 'replaces the replacement but keeps the existing pattern' do
      original_pattern = described_class.masks[:mobile_number][:to_replace]

      described_class.replace_mask(:mobile_number, replacement: '[phone]')

      mobile_number = described_class.masks[:mobile_number]
      expect(mobile_number[:to_replace]).to eq(original_pattern)
      expect(mobile_number[:replacement]).to eq('[phone]')
    end

    it 'replaces both pattern and replacement' do
      described_class.
        replace_mask(:mobile_number, pattern: /Cell \d+/, replacement: '[cell]')

      mobile_number = described_class.masks[:mobile_number]

      expect(mobile_number[:to_replace]).to eq(/Cell \d+/)
      expect(mobile_number[:replacement]).to eq('[cell]')
    end

    it 'raises ArgumentError when the name does not exist' do
      expect { described_class.replace_mask(:nonexistent, pattern: /x/) }.
        to raise_error(ArgumentError, /nonexistent/)
    end
  end
end
