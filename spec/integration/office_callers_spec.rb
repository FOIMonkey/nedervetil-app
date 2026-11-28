require 'spec_helper'

RSpec.describe 'Office files read by their callers, in the worker and here' do
  include DisclosuresHelpers
  include_context 'with document OCR off'

  corpus = OfficeReaderCorpus.files
  rule_texts = [%w[e], %w[words Depot Lorem], %w[zzqqxx]]
  types = { '.docx' => Disclosures::Formats::DOCUMENT['.docx'],
            '.xlsx' => Disclosures::Formats::SPREADSHEET['.xlsx'],
            '.pptx' => Disclosures::Formats::PRESENTATION['.pptx'],
            '.doc' => 'application/msword', '.zip' => 'application/zip' }

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:document) do
    instance_double(Disclosures::Document, info_request: info_request,
                                           requester: owner)
  end

  before do
    sandbox('required')
    problem = AlaveteliSandbox.volume_problem
    skip "the sandbox can't run here: #{problem}" if problem
    begin
      AlaveteliSandbox.self_test
    rescue AlaveteliSandbox::Error => e
      skip "the sandbox can't run here: #{e.message}"
    end
  end

  def sandbox(mode)
    allow(AlaveteliConfiguration).to receive(:sandbox_converters).
      and_return(mode)
  end

  def outcome
    { value: yield }
  rescue StandardError => e
    { error: e.class, message: e.message }
  end

  def both(&block)
    %w[off required].map do |mode|
      sandbox(mode)
      outcome(&block)
    end
  end

  def on_disk(name, bytes)
    Tempfile.create(['office-callers', File.extname(name)]) do |file|
      file.binmode
      file.write(bytes)
      file.close
      yield file.path
    end
  end

  def format_of(name)
    { '.docx' => 'document', '.xlsx' => 'spreadsheet',
      '.pptx' => 'presentation', '.doc' => 'document' }.
      fetch(File.extname(name), 'other')
  end

  def rule(text)
    FactoryBot.create(:info_request_censor_rule, censorable: info_request,
                                                 text: text)
  end

  corpus.each do |name, bytes|
    describe name do
      let(:type) { types.fetch(File.extname(name)) }

      it 'gives the editor the same hidden-content list' do
        on_disk(name, bytes) do |path|
          here, there = both do
            AttachmentManagement::OfficeInspector.findings(path)
          end
          expect(there).to eq(here)
        end
      end

      it 'scores the same hidden content' do
        on_disk(name, bytes) do |path|
          here, there = both do
            Disclosures::HiddenRisk.findings(path, document).map(&:to_h)
          end
          expect(there).to eq(here)
        end
      end

      it 'finds the same rule matches' do
        record = FoiAttachment.new
        format = format_of(name)
        rule_texts.each do |texts|
          rules = texts.map { |text| rule(text) }
          here, there = both do
            Disclosures::RuleCheck.match?(record, bytes, rules: rules,
                                                         format: format)
          end
          expect(there).to eq(here), texts.join(', ')
        end
      end

      it 'reads the same sheets' do
        on_disk(name, bytes) do |path|
          here, there = both do
            Disclosures::Sheets.read_xlsx(path).map(&:to_h)
          end
          expect(there).to eq(here)
        end
      end

      it 'counts the same for the spreadsheet analyser' do
        on_disk(name, bytes) do |path|
          here, there = both { ExcelAnalyzer.metadata_reader.call(path) }
          expect(there).to eq(here)
        end
      end

      it 'decides the same for a spreadsheet hold' do
        attachment = instance_double(FoiAttachment, id: 1)
        allow(attachment).to receive_message_chain(:file, :download).
          and_return(bytes)
        blob = instance_double(ActiveStorage::Blob, content_type: type)
        hold = FoiAttachment::SpreadsheetHold.new(blob, {})
        here, there = both { hold.send(:looks_personal?, attachment) }
        expect(there).to eq(here)
      end

      it 'tidies to the same bytes' do
        allow(AlaveteliConfiguration).
          to receive(:disclosures_remove_office_metadata).and_return(true)
        here, there = both { Disclosures::Tidy.apply(bytes, type, name) }
        expect(there).to eq(here)
      end
    end
  end

  it 'takes a public Office file down when the Office cell refuses a rule’s ' \
     'check' do
    sandbox('off')
    doc = delivered_document(info_request, 'lorem.docx', types.fetch('.docx'),
                             corpus.fetch('lorem.docx'), by: owner)
    publish(doc, by: FactoryBot.create(:admin_user))
    sandbox('required')
    allow_any_instance_of(AlaveteliSandbox::Job).
      to receive(:run_office_read).
      and_raise(AlaveteliSandbox::Refused, 'office: busy')

    expect(
      Disclosures::RuleRemask.apply_to_attachment!(doc.foi_attachment,
                                                   rule('zzqqxx'))
    ).to eq(:left_private)
    expect(doc.reload).not_to be_listed
    expect(doc.foi_attachment.reload).not_to be_is_public
  end

  it 'extracts text from zip archives the same in the worker and here' do
    inner = OfficeFixtures.package({ 'nested.txt' => 'inside nested zip' })
    outer = OfficeFixtures.package({ 'note.txt' => 'top level text',
                                     'inner.zip' => inner })
    [File.binread(file_fixture('example.zip')), outer].each do |archive|
      here, there = both do
        AttachmentToText.from_string(archive, content_type: 'application/zip').
          to_text
      end
      expect(there).to eq(here)
      expect(there).not_to be_empty
    end
  end

  it 'guards LibreOffice’s converted legacy workbook through the worker' do
    xls = File.binread(Rails.root.join('gems/excel_analyzer/spec/fixtures',
                                       'data.xls'))
    here, there = both do
      converted = Disclosures::LegacyOffice.to_ooxml(xls, target: 'xlsx',
                                                          extension: '.xls')
      OfficePackage.package?(converted)
    end
    expect(there).to eq(here)
    expect(there).to eq({ value: true })
  end

  %w[lorem.docx interesting.pptx changes.docx nested.docx].each do |name|
    it "converts #{name} to PDF in the editor with the same findings" do
      bytes = corpus.fetch(name)
      attachment = FactoryBot.create(:body_text)
      revisions = both do
        revision = AttachmentManagement::Revision.create!(
          foi_attachment: attachment, user: owner, kind: 'office_pdf',
          status: 'processing', source_sha256: Digest::SHA256.hexdigest(bytes),
          source_content_type: types.fetch('.docx'), source_filename: name
        )
        AttachmentManagement::Processor.new(revision, source_bytes: bytes).run
        revision.reload.attributes.slice('status', 'error').
          merge('findings' => revision.report&.dig('office_findings'))
      end
      expect(revisions.last).to eq(revisions.first)
    end
  end

  %w[lorem.docx interesting.xlsx sparse.xlsx interesting.pptx changes.docx
     hidden.xlsx states.xlsx nested.docx].each do |name|
    it "renders #{name} the same" do
      bytes = corpus.fetch(name)
      rule('Depot')
      rule('words')
      doc = delivered_document(info_request, name,
                               types.fetch(File.extname(name)), bytes,
                               by: owner, ready: false)
      rendered = both do
        Disclosures::Renderer.new(doc.reload).run
        doc.reload
        [doc.attributes.slice('format', 'page_count', 'render_notes',
                              'hidden_content'),
         doc.pages.order(:number).map do |page|
           page.attributes.slice('number', 'label', 'kind', 'text')
         end]
      end
      expect(rendered.last).to eq(rendered.first)
    end
  end
end
