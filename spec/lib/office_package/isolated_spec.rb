require 'spec_helper'

RSpec.describe OfficePackage::Isolated do
  let(:docx) { File.binread(file_fixture('lorem.docx')) }

  before do
    allow(AlaveteliConfiguration).to receive(:sandbox_converters).
      and_return('required')
    problem = AlaveteliSandbox.volume_problem
    skip "the sandbox can't run here: #{problem}" if problem
  end

  def read(sections, bytes: docx, **options, &block)
    described_class.read(sections, bytes: bytes, **options, &block)
  end

  context 'with the worker' do
    before do
      AlaveteliSandbox.self_test
    rescue AlaveteliSandbox::Error => e
      skip "the sandbox can't run here: #{e.message}"
    end

    it 'reads every section it was made for in one step' do
      expect_any_instance_of(AlaveteliSandbox::Job).
        to receive(:run_office_read).once.and_call_original
      read(%w[guard inspector hidden]) do |file|
        expect(file.value('guard')).to be(true)
        expect(file.value('inspector')).to be_an(Array)
        expect(file.value('hidden')).to all(be_a(OfficePackage::Hidden::Item))
      end
    end

    it 'reads a section it was not made for in a step of its own' do
      expect_any_instance_of(AlaveteliSandbox::Job).
        to receive(:run_office_read).twice.and_call_original
      read(%w[hidden]) do |file|
        file.value('hidden')
        expect(file.value('content_texts')).to include(a_string_matching(/\w/))
      end
    end

    it 'reads in the job it is given' do
      AlaveteliSandbox.job(input: docx, input_name: 'file.docx') do |job|
        expect(AlaveteliSandbox).not_to receive(:job)
        described_class.read(%w[guard], job: job) do |file|
          expect(file.value('guard')).to be(true)
        end
        expect(job.files).to be_empty
      end
    end

    it 'gives the texts the Detector gives its matcher, and keeps none' do
      texts = []
      OfficePackage::Detector.call(docx, ->(text) { texts << text })
      AlaveteliSandbox.job(input: docx, input_name: 'file.docx') do |job|
        given = []
        described_class.read(%w[strings], job: job) do |file|
          file.each_string { |text| given << text }
        end
        expect(given).to eq(texts)
        expect(job.files).to be_empty
      end
    end

    it 'extracts zip entries in the worker and discards the scratch file' do
      archive = OfficeFixtures.package(
        { 'a.txt' => 'alpha', 'b.txt' => 'beta' }
      )
      limits = { max_entries: 10, max_entry: 1024, max_total: 4096 }
      AlaveteliSandbox.job(input: archive, input_name: 'file.zip') do |job|
        extracted = []
        seen = described_class.read_zip(zip: limits, job: job) do |file|
          expect(file.value('guard')).to be(true)
          file.each_zip_entry { |name, data| extracted << [name, data] }
        end
        expect(seen).to eq(2)
        expect(extracted).to eq([%w[a.txt alpha], %w[b.txt beta]])
        expect(job.files).to be_empty
      end
    end

    it 'reads embedded spreadsheets and legacy .xls in the worker and ' \
       'discards the scratch file' do
      fixtures = Rails.root.join('gems/excel_analyzer/spec/fixtures')
      suspect_xlsx = File.binread(fixtures.join('suspect.xlsx'))
      suspect_xls = File.binread(fixtures.join('suspect.xls'))
      embedded_docx = OfficeFixtures.word(
        '<w:p><w:r><w:t>Chart and legacy sheet</w:t></w:r></w:p>',
        parts: {
          'word/embeddings/chart.xlsx' => [nil, suspect_xlsx],
          'word/embeddings/legacy.xls' => [nil, suspect_xls]
        }
      )
      AlaveteliSandbox.job(input: embedded_docx,
                           input_name: 'embedded.docx') do |job|
        legacy = []
        described_class.read(%w[guard embedded_excel], job: job) do |file|
          expect(file.value('guard')).to be(true)
          info = file.value('embedded_excel')
          expect(info[:spreadsheets].size).to eq(1)
          expect(info[:spreadsheets].first[:counts][:hidden_sheets]).to eq(1)
          file.each_embedded_xls { |part, data| legacy << [part, data] }
        end
        expect(legacy).to eq([['word/embeddings/legacy.xls', suspect_xls]])
        expect(job.files).to be_empty
      end
    end
  end

  context 'with a report' do
    let(:report) { {} }
    let(:files) { {} }

    before do
      written = report
      left = files
      allow_any_instance_of(AlaveteliSandbox::Job).
        to receive(:run_office_read) do |job, **|
          File.binwrite(job.scratch('report.json'),
                        written.is_a?(String) ? written : written.to_json)
          left.each { |name, data| File.binwrite(job.scratch(name), data) }
        end
    end

    it 'raises a rubyzip error with its own message' do
      message = "Entry 'xl/a.xml' should be 1B, but is larger when inflated."
      report['guard'] = { 'error' => 'Zip::EntrySizeError',
                          'message' => message }
      read(%w[guard]) do |file|
        expect { file.value('guard') }.
          to raise_error(Zip::EntrySizeError, message)
      end
    end

    it 'raises a guard refusal with its reason and values, worded by the app' do
      report['guard'] = { 'error' => 'OfficePackage::Guard::Refused',
                          'message' => 'sheets', 'reason' => 'sheets',
                          'values' => { 'count' => 200 } }
      read(%w[guard inspector]) do |file|
        expect { AttachmentManagement::ZipGuard.checked!(file) }.to raise_error(
          AttachmentManagement::ZipGuard::Refused,
          'This file is too large or too complex to process here ' \
          '(more than 200 sheets).'
        )
        expect { file.value('inspector') }.
          to raise_error(OfficePackage::Guard::Refused, 'sheets')
      end
    end

    it 'raises a sheets refusal and a reader error as their own' do
      report.merge!(
        'sheets' => { 'error' => 'OfficePackage::Sheets::Refused',
                      'message' => 'too_large_to_copy',
                      'reason' => 'too_large_to_copy' },
        'hidden' => { 'error' => 'OfficePackage::Refused',
                      'message' => 'a part over the size limit' }
      )
      sheets = Disclosures::Sheets.limits
      read(%w[sheets hidden], sheets: sheets) do |file|
        expect { file.value('sheets') }.to raise_error(
          OfficePackage::Sheets::Refused, 'too_large_to_copy'
        ) { |error| expect(error.reason).to eq('too_large_to_copy') }
        expect { file.value('hidden') }.
          to raise_error(OfficePackage::Refused, 'a part over the size limit')
      end
    end

    it 'raises an error it does not rebuild with the reader’s message' do
      report['excel'] = { 'error' => 'Disclosures::Error::NeedsAdmin',
                          'message' => 'undefined method' }
      read(%w[excel]) do |file|
        expect { file.value('excel') }.
          to raise_error(described_class::ReaderError, 'undefined method')
      end
    end

    it 'gives each section’s value as the reader in the app gives it' do
      counts = { 'data_model' => 0, 'external_links' => 0,
                 'hidden_columns' => 0, 'hidden_rows' => 2,
                 'hidden_sheets' => 0, 'named_ranges' => 0,
                 'pivot_cache' => 0 }
      report.merge!(
        'hidden' => { 'value' => [{ 'type' => 'hidden_sheet', 'count' => nil,
                                    'name' => 'Staff', 'texts' => ['Jane'],
                                    'readable' => true }] },
        'excel' => { 'value' => counts }
      )
      read(%w[hidden excel]) do |file|
        expect(file.value('hidden')).to eq(
          [OfficePackage::Hidden::Item.new(type: 'hidden_sheet', count: nil,
                                           name: 'Staff', texts: ['Jane'],
                                           readable: true)]
        )
        expect(file.value('excel')).to eq(counts.transform_keys(&:to_sym))
      end
    end

    it 'gives the tidied bytes, or the file’s own when nothing changed' do
      report['tidy'] = { 'value' => { 'changed' => true, 'removed' => {},
                                      'kept' => {} } }
      files['tidied'] = 'tidied bytes'
      read(%w[tidy]) do |file|
        expect(file.value('tidy')).to eq('tidied bytes')
      end
      report['tidy'] = { 'value' => { 'changed' => false, 'removed' => {},
                                      'kept' => {} } }
      files.clear
      read(%w[tidy]) { |file| expect(file.value('tidy') == docx).to be(true) }

      report['tidy'] = { 'value' => { 'changed' => true, 'removed' => {},
                                      'kept' => {} } }
      read(%w[tidy]) do |file|
        expect { file.value('tidy') }.to raise_error(
          AlaveteliSandbox::Failed, /report can't be used/
        )
      end
    end

    it 'reads zip entries from a valid manifest and refuses an out-of-bounds ' \
       'slice' do
      limits = { max_entries: 10, max_entry: 1024, max_total: 4096 }
      report['guard'] = { 'value' => true }
      report['zip_entries'] = {
        'value' => {
          'seen' => 2,
          'entries' => [{ 'name' => 'a.txt', 'offset' => 0, 'size' => 5 }]
        }
      }
      files['zip_entries'] = 'hello'
      got = []
      seen = described_class.read_zip(zip: limits, bytes: docx) do |file|
        file.each_zip_entry { |name, data| got << [name, data] }
      end
      expect(seen).to eq(2)
      expect(got).to eq([%w[a.txt hello]])

      report['zip_entries']['value']['entries'] = [
        { 'name' => 'a.txt', 'offset' => 3, 'size' => 5 }
      ]
      described_class.read_zip(zip: limits, bytes: docx) do |file|
        expect { file.each_zip_entry { nil } }.to raise_error(
          AlaveteliSandbox::Failed, /report can't be used/
        )
      end
    end

    it 'gives a section a failed guard kept from being read that guard’s error' do
      report['guard_unpack'] = { 'error' => 'OfficePackage::Guard::Refused',
                                 'message' => 'parts', 'reason' => 'parts',
                                 'values' => { 'count' => 5000 } }
      read(%w[guard_unpack hidden]) do |file|
        expect { file.value('hidden') }.to raise_error(
          OfficePackage::Guard::Refused, 'parts'
        ) { |error| expect(error.values).to eq(count: 5000) }
      end
    end

    it 'fails when the report is not what the worker writes' do
      allow(Rails.logger).to receive(:warn)
      ['not json', { 'guard' => 'yes' }.to_json,
       { 'guard' => { 'value' => false } }.to_json,
       { 'hidden' => { 'value' => [{ 'kind' => 'x' }] } }.to_json, {}.to_json].
        each do |given|
          allow_any_instance_of(AlaveteliSandbox::Job).
            to receive(:run_office_read) do |job, **|
              File.binwrite(job.scratch('report.json'), given)
            end
          read(%w[guard hidden]) do |file|
            expect { file.value('guard') }.to raise_error(
              AlaveteliSandbox::Failed, /report can't be used/
            ), given
          end
        end
    end

    it 'rejects malformed or incomplete excel and embedded_excel counts' do
      full = { 'data_model' => 0, 'external_links' => 0,
               'hidden_columns' => 0, 'hidden_rows' => 0,
               'hidden_sheets' => 0, 'named_ranges' => 0,
               'pivot_cache' => 0 }
      [
        ['excel', { 'excel' => { 'value' => {} } }],
        ['excel', { 'excel' => { 'value' => full.except('hidden_sheets') } }],
        ['excel',
         { 'excel' => { 'value' => full.merge('hidden_rows' => 'bad') } }],
        ['excel',
         { 'excel' => { 'value' => full.merge('hidden_rows' => -1) } }],
        ['excel', { 'excel' => { 'value' => full.merge('error' => 1) } }],
        ['embedded_excel',
         { 'embedded_excel' => {
           'value' => {
             'spreadsheets' => [{ 'part' => 'a.xlsx',
                                  'counts' => {} }],
             'errors' => [], 'legacy_xls' => []
           }
         } }],
        ['embedded_excel',
         { 'embedded_excel' => {
           'value' => {
             'spreadsheets' => [
               { 'part' => 'a.xlsx',
                 'counts' => full.merge('hidden_sheets' => -1) }
             ],
             'errors' => [], 'legacy_xls' => []
           }
         } }]
      ].each do |section, body|
        allow_any_instance_of(AlaveteliSandbox::Job).
          to receive(:run_office_read) do |job, **|
            File.binwrite(job.scratch('report.json'), body.to_json)
          end
        read([section]) do |file|
          expect { file.value(section) }.to raise_error(
            AlaveteliSandbox::Failed, /report can't be used/
          )
        end
      end
    end

    it 'rejects oversized embedded_excel and zip_entries manifests' do
      too_many_xls = Array.new(
        OfficePackage::ExcelMetadata::MAX_EMBEDDED_XLS + 1
      ) { { 'part' => 'a.xls', 'offset' => 0, 'size' => 1 } }
      too_big_slices = Array.new(3) do
        { 'name' => 'a.txt', 'offset' => 0,
          'size' => AlaveteliSandbox::OfficeStep::ZIP_LIMITS[:max_total] }
      end
      [
        ['embedded_excel',
         { 'embedded_excel' => {
           'value' => { 'spreadsheets' => [], 'errors' => [],
                        'legacy_xls' => too_many_xls }
         } }],
        ['zip_entries',
         { 'zip_entries' => {
           'value' => { 'seen' => 3, 'entries' => too_big_slices,
                        'skipped' => [] }
         } }]
      ].each do |section, body|
        allow_any_instance_of(AlaveteliSandbox::Job).
          to receive(:run_office_read) do |job, **|
            File.binwrite(job.scratch('report.json'), body.to_json)
          end
        read([section]) do |file|
          expect { file.value(section) }.to raise_error(
            AlaveteliSandbox::Failed, /report can't be used/
          )
        end
      end
    end
  end

  context 'when the step does not finish' do
    def step_raises(error)
      allow_any_instance_of(AlaveteliSandbox::Job).
        to receive(:run_office_read).and_raise(error)
    end

    it 'raises for each section what its reader raises past its limits ' \
       'when the worker ran out of memory' do
      result = instance_double(AlaveteliSandbox::ProcessRunner::Result,
                               stderr: "TooLarge: NoMemoryError\n")
      step_raises(AlaveteliSandbox::Failed.new('office-worker failed', result))
      read(%w[guard guard_unpack sheets hidden inspector],
           sheets: Disclosures::Sheets.limits) do |file|
        expect { file.value('guard') }.to raise_error(
          OfficePackage::Guard::Refused, 'unpacked'
        ) { |error| expect(error.values).to eq(size: OfficePackage::MAX_TOTAL) }
        expect { file.value('guard_unpack') }.
          to raise_error(OfficePackage::Guard::Refused, 'unpacked')
        expect { file.value('sheets') }.
          to raise_error(OfficePackage::Sheets::Refused, 'too_large_to_read')
        expect { file.value('hidden') }.to raise_error(OfficePackage::Refused)
        expect { file.value('inspector') }.
          to raise_error(OfficePackage::Refused)
      end
    end

    it 'counts Ruby’s own allocation abort as out of memory' do
      result = instance_double(AlaveteliSandbox::ProcessRunner::Result,
                               stderr: "[FATAL] failed to allocate memory\n")
      step_raises(AlaveteliSandbox::Failed.new('office-worker failed', result))
      read(%w[hidden]) do |file|
        expect { file.value('hidden') }.to raise_error(OfficePackage::Refused)
      end
    end

    it 'raises a refusal, a timeout or any other failure as the step did' do
      result = instance_double(AlaveteliSandbox::ProcessRunner::Result,
                               stderr: "NoMethodError: x\n")
      [AlaveteliSandbox::Refused.new('office: busy'),
       AlaveteliSandbox::TimedOut.new('office-worker timed out'),
       AlaveteliSandbox::Failed.new('office-worker failed', result),
       AlaveteliSandbox::Failed.new('killed')].each do |error|
        step_raises(error)
        read(%w[guard]) do |file|
          expect { file.value('guard') }.to raise_error(error)
        end
      end
    end
  end
end
