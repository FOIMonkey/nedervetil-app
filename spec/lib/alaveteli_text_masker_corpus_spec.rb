require 'spec_helper'
require 'digest'

# Synthetic corpus compared against spec/fixtures/files/text_masker_corpus.json.
# Masked PDFs are recorded by extracted text because re-masking varies bytes.
#
# Regenerate after an intentional masking change:
#   TEXT_MASKER_CORPUS=record bundle exec rspec \
#     spec/lib/alaveteli_text_masker_corpus_spec.rb
#
# Page-image digests depend on local tools, so they are not recorded; set
# TEXT_MASKER_CORPUS_PICTURES=<file> to compare runs on one machine.
RSpec.describe 'What the text masker gives back for each kind of content' do
  def self.record_path
    Rails.root.join('spec/fixtures/files/text_masker_corpus.json')
  end

  def self.recorded
    @recorded ||= record_path.exist? ? JSON.parse(record_path.read) : {}
  end

  def self.made
    return superclass.made if superclass.respond_to?(:made)

    @made ||= {}
  end

  def self.pictures
    return superclass.pictures if superclass.respond_to?(:pictures)

    @pictures ||= {}
  end

  after(:all) do
    group = self.class
    if ENV['TEXT_MASKER_CORPUS'] == 'record'
      group.record_path.
        write("#{JSON.pretty_generate(group.made.sort.to_h)}\n")
    end
    if ENV['TEXT_MASKER_CORPUS_PICTURES'].present?
      File.write(ENV['TEXT_MASKER_CORPUS_PICTURES'],
                 "#{JSON.pretty_generate(group.pictures.sort.to_h)}\n")
    end
  end

  # Unsaved so matching rules do not persist redaction records.
  let(:redactable) { FactoryBot.build(:incoming_message) }

  let(:told) { [] }
  let(:asked) { [] }
  let(:logged) { [] }

  let(:name_rule) do
    watched(FactoryBot.build(:censor_rule, text: 'Jane Doelittle',
                                           replacement: '[name]'))
  end
  let(:reference_rule) do
    watched(FactoryBot.build(:censor_rule, text: 'ref-\d+',
                                           replacement: '[ref]',
                                           regexp: true))
  end
  let(:request_masks) do
    [{ to_replace: 'foi@gritshire.example',
       replacement: '[Gritshire Council request email]' }]
  end
  let(:letter_text) do
    "Dear Jane Doelittle,\n" \
      "Your request ref-20451 was passed to clerk@gritshire.example.\n" \
      "Reply to foi@gritshire.example or call Mobile: 07700 900123.\n" \
      "Sign in at http://#{AlaveteliConfiguration.domain}/c/abcdef123456 " \
      "to follow it.\n"
  end
  let(:letter_pdf) do
    AttachmentFixtures.pdf(
      pages: [
        AttachmentFixtures.letter_page(
          secret: 'Meeting with Jane Doelittle about ref-20451'
        ),
        AttachmentFixtures.letter_page(
          secret: 'Write to clerk@gritshire.example or foi@gritshire.example'
        )
      ]
    )
  end

  before do
    allow(PDFRedactor).to receive(:redact).
      and_wrap_original do |original, pdf, rules, **options|
        asked << { 'rules' => rules.size, 'options' => options.stringify_keys }
        original.call(pdf, rules, **options)
      end
    %i[info warn].each do |level|
      allow(Rails.logger).to receive(level).
        and_wrap_original do |original, *args, &block|
          line = args.first.to_s
          if line.start_with?('[masking]')
            logged << "#{level}: #{plain_log(line)}"
          end
          original.call(*args, &block)
        end
    end
  end

  def watched(rule)
    %i[record_match apply_to_text apply_to_binary].each do |name|
      allow(rule).to receive(name).
        and_wrap_original do |original, *args, **keywords|
          told << heard(rule, name, args, keywords)
          original.call(*args, **keywords)
        end
    end
    rule
  end

  def heard(rule, name, args, keywords)
    given, attribute =
      if name == :record_match
        args
      else
        keywords.values_at(:redactable, :redacted_attribute)
      end
    row = { 'rule' => rule.text, 'call' => name.to_s,
            'given_what_is_masked' => given.equal?(redactable),
            'attribute' => attribute&.to_s }
    row['matched'] = keywords[:matched] if keywords.key?(:matched)
    row
  end

  # Strip sandbox context and tool output (which includes temporary paths).
  def plain_log(line)
    line = line.sub(AlaveteliSandbox.context, '').strip
    line[/\A\[masking\] PDF not masked: [\w:]+/] || line
  end

  def text_of(pdf)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'masked.pdf')
      File.binwrite(path, pdf)
      AttachmentFixtures.pdf_text(path)
    end
  end

  def pictures_of(name, pdf)
    return unless ENV['TEXT_MASKER_CORPUS_PICTURES'].present?

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'masked.pdf')
      File.binwrite(path, pdf)
      self.class.pictures[name] =
        AttachmentFixtures.render_pages(path, dir).map do |png|
          Digest::SHA256.file(png).hexdigest
        end
    end
  end

  def shape(name, result, content_type, given)
    return nil if result.nil?

    if content_type == 'application/pdf' && result.start_with?('%PDF')
      return { 'pdf' => 'as it came' } if result == given

      pictures_of(name, result)
      return { 'pdf_text' => text_of(result) }
    end

    utf8 = result.dup.force_encoding('UTF-8')
    if utf8.valid_encoding? && utf8.exclude?("\0") && utf8.length <= 1_500
      { 'text' => utf8 }
    else
      { 'bytes' => result.bytesize,
        'sha256' => Digest::SHA256.hexdigest(result) }
    end
  end

  def masked(name, content, content_type, masker: AlaveteliTextMasker,
             **options)
    given = content&.dup
    unmasked = []
    options = options.merge(unmasked: unmasked, redactable: redactable,
                            redacted_attribute: :body)
    outcome =
      begin
        result = masker.apply_masks(content, content_type, options)
        { 'result' => shape(name, result, content_type, given),
          'changed' => result != given }
      rescue AlaveteliTextMasker::PDFMaskingError => e
        { 'raises' => e.class.name }
      end
    outcome.merge('input_left_alone' => content == given,
                  'went_out_as_it_came' => unmasked,
                  'rules_told' => told, 'redactor_asked' => asked,
                  'logged' => logged)
  end

  def compare(name, outcome)
    outcome = JSON.parse(outcome.to_json)
    self.class.made[name] = outcome
    return if ENV['TEXT_MASKER_CORPUS'] == 'record'

    expect(outcome).to eq(self.class.recorded.fetch(name))
  end

  def check(name, content, content_type, **options)
    compare name, masked(name, content, content_type, **options)
  end

  describe 'text' do
    it 'a letter, with the default masks' do
      check 'text: a letter, with the default masks',
            letter_text, 'text/plain'
    end

    it 'a letter, with censor rules and no default masks' do
      check 'text: a letter, with censor rules and no default masks',
            letter_text, 'text/plain',
            censor_rules: [name_rule, reference_rule], default_masks: false
    end

    it 'a letter, with the request masks, the default masks and rules' do
      check 'text: a letter, with every mask and rule',
            letter_text, 'text/plain',
            masks: request_masks, censor_rules: [name_rule, reference_rule]
    end

    it 'a letter, with a mask that is blank, which is left out' do
      check 'text: with a mask that is blank', letter_text, 'text/plain',
            masks: [{ to_replace: '', replacement: '[nothing]' },
                    { to_replace: nil, replacement: '[nothing]' }]
    end

    it 'a rule that matches what a mask put in' do
      rule = watched(FactoryBot.build(:censor_rule, text: 'email address',
                                                    replacement: 'contact'))
      check 'text: a rule that matches what a mask put in',
            letter_text, 'text/plain', censor_rules: [rule]
    end

    it 'a web page' do
      html = '<p>Write to <a href="mailto:clerk@gritshire.example">' \
             'clerk@gritshire.example</a> about Jane Doelittle.</p>'
      check 'text: a web page', html, 'text/html', censor_rules: [name_rule]
    end

    it 'a CSV file' do
      check 'text: a CSV file',
            "Name,Contact\nJane Doelittle,jane@gritshire.example\n",
            'text/csv', censor_rules: [name_rule]
    end

    it 'nothing at all' do
      check 'text: nothing at all', nil, 'text/plain',
            censor_rules: [name_rule]
    end
  end

  describe 'bytes' do
    let(:word) do
      "\xD0\xCF\x11\xE0 Jane Doelittle wrote from jane@gritshire.example " \
        "about ref-20451 \xFF\xFE".b
    end

    it 'a Word 97 file, with the default masks' do
      check 'bytes: a Word 97 file, with the default masks',
            word, 'application/msword'
    end

    it 'a Word 97 file, with censor rules' do
      check 'bytes: a Word 97 file, with censor rules',
            word, 'application/msword',
            censor_rules: [name_rule, reference_rule]
    end

    it 'a Word 97 file, with censor rules and no default masks' do
      check 'bytes: a Word 97 file, with rules and no default masks',
            word, 'application/msword',
            censor_rules: [name_rule], default_masks: false
    end

    it 'a rule that only works on text' do
      rule = watched(FactoryBot.build(:censor_rule, text: '\p{Lu}ane',
                                                    regexp: true))
      allow(rule).to receive(:id).and_return(41)
      check 'bytes: a rule that only works on text',
            word, 'application/msword', censor_rules: [rule, name_rule]
    end

    # Binary formats use byte offsets, so the byte pass refuses size changes.
    it 'a rule that would change the size, which is refused' do
      rule = FactoryBot.build(:censor_rule, text: 'Jane Doelittle')
      allow(rule).to receive(:apply_to_binary).and_return('shorter'.b)

      expect do
        AlaveteliTextMasker.apply_masks(word, 'application/msword',
                                        censor_rules: [rule])
      end.to raise_error(RuntimeError, /internal error/)
    end

    it 'an address in two-byte text' do
      wide = 'Write to jane@gritshire.example today'.encode('UTF-16LE').b
      check 'bytes: an address in two-byte text',
            "\xD0\xCF\x11\xE0".b + wide, 'application/vnd.ms-excel'
    end

    it 'a large file of two-byte text' do
      filler = ('The depot rota. ' * 40_000).encode('UTF-16LE').b
      wide = 'Write to jane@gritshire.example today'.encode('UTF-16LE').b
      check 'bytes: a large file of two-byte text',
            filler + wide + filler, 'application/octet-stream'
    end

    it 'a kind of file nothing knows' do
      check 'bytes: a kind of file nothing knows',
            "\x01\x02 jane@gritshire.example \x03".b,
            'application/x-unknown', censor_rules: [name_rule]
    end

    it 'an OpenDocument file saved as flat XML' do
      check 'bytes: an OpenDocument file saved as flat XML',
            '<office:text>jane@gritshire.example</office:text>'.b,
            'application/vnd.oasis.opendocument.text-flat-xml'
    end
  end

  describe 'what is never masked' do
    it 'a picture' do
      check 'never masked: a picture',
            "\x89PNG\r\n\x1A\n jane@gritshire.example".b,
            'image/png', censor_rules: [name_rule]
    end

    it 'a zip file' do
      check 'never masked: a zip file',
            "PK\x03\x04 jane@gritshire.example".b,
            'application/zip', censor_rules: [name_rule]
    end

    it 'a zip file, with no censor rules' do
      check 'never masked: a zip file, with no censor rules',
            "PK\x03\x04 jane@gritshire.example".b, 'application/zip'
    end

    it 'a Word file stored as a zip' do
      check 'never masked: a Word file stored as a zip',
            "PK\x03\x04 jane@gritshire.example".b,
            Disclosures::Formats::DOCUMENT['.docx']
    end

    it 'a zip file sent as something else' do
      check 'never masked: a zip file sent as something else',
            "PK\x03\x04 jane@gritshire.example".b,
            'application/octet-stream', censor_rules: [name_rule]
    end

    it 'an OpenDocument file' do
      check 'never masked: an OpenDocument file',
            'jane@gritshire.example'.b,
            'application/vnd.oasis.opendocument.text'
    end
  end

  describe 'a PDF' do
    it 'with the default masks' do
      check 'PDF: with the default masks', letter_pdf, 'application/pdf'
    end

    it 'with censor rules and the request masks' do
      check 'PDF: with censor rules and the request masks',
            letter_pdf, 'application/pdf',
            masks: request_masks, censor_rules: [name_rule, reference_rule]
    end

    it 'with censor rules and no default masks' do
      check 'PDF: with censor rules and no default masks',
            letter_pdf, 'application/pdf',
            censor_rules: [name_rule], default_masks: false
    end

    it 'with a mask that is blank, which is left out' do
      check 'PDF: with a mask that is blank', letter_pdf, 'application/pdf',
            masks: [{ to_replace: '', replacement: '[nothing]' }]
    end

    it 'with a rule on the request, which has scanned pages read' do
      rule = watched(
        FactoryBot.build(:censor_rule, text: 'Jane Doelittle',
                                       censorable_type: 'InfoRequest')
      )
      check 'PDF: with a rule on the request', letter_pdf, 'application/pdf',
            censor_rules: [rule]
    end

    it 'with a rule on the user, which has scanned pages read' do
      rule = watched(
        FactoryBot.build(:censor_rule, text: 'Jane Doelittle',
                                       censorable_type: 'User')
      )
      check 'PDF: with a rule on the user', letter_pdf, 'application/pdf',
            censor_rules: [rule]
    end

    it 'masked before, with nothing for a rule to change' do
      rule = watched(FactoryBot.build(:censor_rule, text: 'Zebracorn'))
      check 'PDF: masked before, with nothing for a rule to change',
            letter_pdf, 'application/pdf',
            censor_rules: [rule], default_masks: false, masked: true
    end

    it 'masked before, with a rule that changes it' do
      check 'PDF: masked before, with a rule that changes it',
            letter_pdf, 'application/pdf',
            censor_rules: [name_rule], default_masks: false, masked: true
    end

    it 'that needs a password' do
      check 'PDF: that needs a password',
            AttachmentFixtures.encrypted_pdf(letter_pdf),
            'application/pdf', censor_rules: [name_rule]
    end

    it 'that is not a PDF' do
      check 'PDF: that is not a PDF', 'not a PDF at all'.b,
            'application/pdf', censor_rules: [name_rule]
    end
  end

  describe 'masks of its own' do
    let(:masker) do
      Class.new { include AlaveteliTextMasker }.new.tap do |own|
        own.add_mask(:postcode, pattern: /\b[A-Z]{2}\d \d[A-Z]{2}\b/,
                                replacement: '[postcode]')
        own.replace_mask(:mobile_number, replacement: '[mobile]')
        own.remove_mask(:login_link)
      end
    end
    let(:addressed) { "#{letter_text}Depot at GR1 4AB.\n" }

    it 'are used for text' do
      check 'own masks: for text', addressed, 'text/plain', masker: masker
    end

    it 'are used for a PDF' do
      pdf = AttachmentFixtures.pdf(
        pages: [AttachmentFixtures.letter_page(
          secret: 'Depot at GR1 4AB, Mobile: 07700 900123'
        )]
      )
      check 'own masks: for a PDF', pdf, 'application/pdf', masker: masker
    end

    it 'are not used by the masker itself' do
      check 'own masks: not used by the masker itself',
            addressed, 'text/plain'
    end
  end

  describe 'what it tells others' do
    def rule_shape(rule)
      rule.to_a.map { |part| part.is_a?(Regexp) ? part.inspect : part }
    end

    it 'the PDF rules for a set of censor rules and masks' do
      rules = AlaveteliTextMasker.pdf_rules([name_rule, reference_rule],
                                            masks: request_masks)
      bare = AlaveteliTextMasker.pdf_rules([name_rule], default_masks: false)
      compare 'the PDF rules for censor rules and masks',
              { 'with masks' => rules.map { |rule| rule_shape(rule) },
                'without default masks' => bare.map { |r| rule_shape(r) } }
    end

    it 'which content is an archive' do
      tried = {
        'application/zip' => '',
        'APPLICATION/ZIP' => '',
        Disclosures::Formats::DOCUMENT['.docx'] => '',
        'application/vnd.ms-excel.sheet.macroEnabled.12' => '',
        'application/vnd.ms-excel' => "\xD0\xCF\x11\xE0",
        'application/msword' => "\xD0\xCF\x11\xE0",
        'application/vnd.oasis.opendocument.text' => '',
        'application/vnd.oasis.opendocument.text-flat-xml' => '<office',
        'application/octet-stream' => "PK\x03\x04",
        'application/x-unknown' => "7z\xBC\xAF\x27\x1C",
        'application/gzip' => Zlib.gzip('The depot rota'),
        'application/x-rar' => "Rar!\x1A\x07",
        'application/pdf' => '%PDF-1.4',
        'text/plain' => 'PK'
      }
      compare('which content is an archive',
              tried.to_h { |type, head|
                [type, AlaveteliTextMasker.archive?(type, head.b)]
              })
    end

    it 'that a signature counts only at the start of a file' do
      held = "Depot rota PK\x03\x04 jane@gritshire.example".b
      expect(AlaveteliTextMasker.archive?('application/octet-stream', held)).
        to be(false)

      unmasked = []
      masked = AlaveteliTextMasker.apply_masks(held, 'application/octet-stream',
                                               unmasked: unmasked)
      expect(masked).to eq("Depot rota PK\x03\x04 xxxx@xxxxxxxxx.xxxxxxx".b)
      expect(unmasked).to be_empty
    end
  end
end
