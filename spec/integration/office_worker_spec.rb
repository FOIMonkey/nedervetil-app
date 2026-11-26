require 'spec_helper'
require 'open3'

RSpec.describe 'Reading Office files in the Office worker' do
  corpus = OfficeReaderCorpus.files
  step = AlaveteliSandbox::OfficeStep
  everything = step::SECTIONS
  unguarded = everything - %w[guard guard_unpack]

  let(:sheets) do
    { max_rows: Disclosures.sheet_max_rows,
      max_columns: Disclosures.sheet_max_columns,
      max_cells: Disclosures::Sheets::MAX_CELLS,
      max_read_cells: Disclosures::Sheets::MAX_READ_CELLS }
  end
  let(:whole_sheets) { sheets.merge(max_rows: nil, max_columns: nil) }
  let(:zip_limits) do
    { max_entries: AttachmentToText::MAX_ZIP_ENTRIES,
      max_entry: AttachmentToText::MAX_ZIP_ENTRY,
      max_total: AttachmentToText::MAX_ZIP_TOTAL }
  end

  def as_json(data)
    JSON.parse(JSON.generate(data))
  end

  def answer
    { 'value' => as_json(yield) }
  rescue StandardError => e
    answer = { 'error' => e.class.name, 'message' => e.message }
    answer['reason'] = e.reason if e.respond_to?(:reason)
    answer['values'] = as_json(e.values) if e.respond_to?(:values)
    answer
  end

  # Memoized per file because Detector runs once per text to isolate each Hit.
  detector_lines = {}
  define_method(:detector_lines) do |bytes|
    detector_lines[bytes] ||= detector_lines_of(bytes)
  end

  def detector_lines_of(bytes)
    texts = []
    result = OfficePackage::Detector.call(bytes, ->(text) {
      texts << text
      false
    })
    lines = texts.each_index.map do |index|
      calls = 0
      matcher = ->(_text) { (calls += 1) == index + 1 }
      hit = OfficePackage::Detector.call(bytes, matcher).hits.sole
      [hit.part, hit.where, texts[index]]
    end
    [lines, result.not_checked]
  end

  def app_readers(path, bytes, limits, found)
    {
      'guard' => -> { OfficePackage::Guard.check!(path) },
      'guard_unpack' => -> { OfficePackage::Guard.check!(path, unpack: true) },
      'inspector' => -> { OfficePackage::Inspector.findings(path) },
      'hidden' => -> { OfficePackage::Hidden.call(bytes).map(&:to_h) },
      'content_texts' => -> {
        OfficePackage::Hidden.new(OfficePackage.read(bytes)).content_texts
      },
      'strings' => -> {
        found[:strings], not_checked = detector_lines(bytes)
        { not_checked: not_checked }
      },
      'sheets' => -> {
        OfficePackage::Sheets.read_xlsx(path, **limits[:sheets])
      },
      'excel' => -> { OfficePackage::ExcelMetadata.call(bytes) },
      'embedded_excel' => -> { app_embedded_excel(bytes, found) },
      'tidy' => -> {
        result = OfficePackage::Tidy.call(bytes)
        found[:tidied] = result.bytes.b unless result.bytes.b == bytes.b
        { changed: result.changed?, removed: result.removed,
          kept: result.kept }
      },
      'zip_entries' => -> { app_zip_entries(path, limits[:zip], found) }
    }
  end

  def app_embedded_excel(bytes, found)
    legacy = []
    data = +''.b
    result = OfficePackage::ExcelMetadata.embedded(bytes) do |part, body|
      legacy << { part: part.dup.force_encoding('UTF-8').scrub,
                  offset: data.bytesize, size: body.bytesize }
      data << body
    end
    found[:embedded_xls] = data unless legacy.empty?
    result.merge(legacy_xls: legacy)
  end

  def app_zip_entries(path, limits, found)
    entries = []
    positions = []
    skipped = []
    data = +''.b
    seen = OfficePackage::Guard.each_entry(
      path, **limits, positions: positions, skipped: skipped
    ) do |name, body|
      entries << { name: name.dup.force_encoding('UTF-8').scrub,
                   offset: data.bytesize, size: body.bytesize,
                   index: positions.last }
      data << body
    end
    found[:zip_entries] = data
    { entries: entries, seen: seen,
      skipped: skipped.map { |n| n.dup.force_encoding('UTF-8').scrub } }
  end

  def in_app(bytes, sections, sheets: nil, zip: nil)
    Tempfile.create('office-worker-spec') do |file|
      file.binmode
      file.write(bytes)
      file.close
      found = { strings: nil, tidied: nil, zip_entries: nil, embedded_xls: nil }
      readers = app_readers(file.path, bytes, { sheets: sheets, zip: zip },
                            found)
      guards, others = (AlaveteliSandbox::OfficeStep::SECTIONS & sections).
                       partition { |section| section.start_with?('guard') }
      report = guards.to_h do |section|
        [section, answer(&readers.fetch(section))]
      end
      if report.values.all? { |given| given.key?('value') }
        others.each do |section|
          report[section] = answer(&readers.fetch(section))
        end
      end
      found.merge(report: report)
    end
  end

  def left
    strings = yield(AlaveteliSandbox::OfficeStep::STRINGS)
    { report: JSON.parse(yield(AlaveteliSandbox::OfficeStep::REPORT)),
      strings: strings&.lines&.map { |line| JSON.parse(line) },
      tidied: yield(AlaveteliSandbox::OfficeStep::TIDIED),
      zip_entries: yield(AlaveteliSandbox::OfficeStep::ZIP_ENTRIES),
      embedded_xls: yield(AlaveteliSandbox::OfficeStep::EMBEDDED_XLS) }
  end

  def job_left(bytes, name, sections, sheets, zip = nil)
    AlaveteliSandbox.job(input: bytes, input_name: name) do |job|
      job.run_office_read(sections: sections, sheets: sheets, zip: zip)
      left do |file|
        job.read(file, max: 64 * 1024 * 1024) if job.exist?(file)
      end
    end
  end

  def made_big
    rows = Array.new(40_000) { |r| Array.new(8) { |c| "v#{r}-#{c}" } }
    OfficeFixtures.workbook(
      sheets: { 'xl/worksheets/sheet1.xml' => OfficeFixtures.sheet_xml(rows) }
    )
  end

  context 'on its own' do
    def run_worker(bytes, sections, limits: {}, rlimit_as: nil,
                   gems: AlaveteliSandbox::OfficeStep.gem_directories)
      Dir.mktmpdir('office-worker-spec') do |dir|
        scratch = File.join(dir, 'scratch')
        Dir.mkdir(scratch)
        path = File.join(dir, 'file')
        File.binwrite(path, bytes)
        # RubyGems sets Bundler up as it loads if BUNDLER_SETUP is set.
        environment = (%w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH] +
                       ENV.keys.grep(/\ABUNDLE/)).to_h { |name| [name, nil] }
        _out, errors, status = Open3.capture3(
          environment, RbConfig.ruby, '--disable-gems',
          *gems.flat_map { |gem| ['-I', gem] },
          Rails.root.join('script/office_worker.rb').to_s, path, scratch,
          *AlaveteliSandbox::OfficeStep.arguments(
            sections, limits[:sheets], limits[:zip]
          ),
          **{ rlimit_as: rlimit_as }.compact
        )
        yield status, errors, scratch
      end
    end

    def worker_left(bytes, sections, sheets: nil, zip: nil)
      run_worker(bytes, sections,
                 limits: { sheets: sheets, zip: zip }) do |status, errors, dir|
        expect(status).to be_success, errors
        expect(errors).to eq('')
        left do |name|
          path = File.join(dir, name)
          File.binread(path) if File.exist?(path)
        end
      end
    end

    corpus.each do |name, bytes|
      describe name do
        it 'gives what the readers in the app give, every section' do
          expect(
            worker_left(bytes, everything, sheets: sheets, zip: zip_limits)
          ).to eq(in_app(bytes, everything, sheets: sheets, zip: zip_limits))
        end

        it 'gives what the readers in the app give, with no guard' do
          expect(
            worker_left(bytes, unguarded, sheets: sheets, zip: zip_limits)
          ).to eq(in_app(bytes, unguarded, sheets: sheets, zip: zip_limits))
        end

        it 'gives what the app gives for whole sheets' do
          expect(worker_left(bytes, %w[sheets], sheets: whole_sheets)).
            to eq(in_app(bytes, %w[sheets], sheets: whole_sheets))
        end
      end
    end

    it 'reads nothing else once a guard refuses' do
      report = worker_left(corpus.fetch('many-sheets.xlsx'),
                           %w[guard inspector hidden])[:report]
      expect(report).to eq(
        'guard' => { 'error' => 'OfficePackage::Guard::Refused',
                     'message' => 'sheets', 'reason' => 'sheets',
                     'values' => { 'count' => 200 } }
      )
    end

    it 'gives a nested file’s texts under its name' do
      lines = worker_left(corpus.fetch('nested.docx'), %w[strings])[:strings]
      expect(lines).to include(
        ['word/embeddings/inner.docx/word/document.xml', 'text',
         "inner words\u0000"],
        ['word/embeddings/oleObject1.bin/Contents', 'strings',
         'compound words']
      )
    end

    it 'leaves no texts when the Detector refuses part way' do
      run_worker(corpus.fetch('doctype.xlsx'),
                 %w[strings]) do |status, _errors, scratch|
        expect(status).to be_success
        report = JSON.parse(File.read(File.join(scratch, 'report.json')))
        expect(report['strings']).
          to include('error' => 'OfficePackage::Refused')
        expect(Dir.children(scratch)).to eq(['report.json'])
      end
    end

    it 'says it could not load its code, and nothing else, on stderr' do
      run_worker(corpus.fetch('lorem.docx'), %w[guard],
                 gems: []) do |status, errors, scratch|
        expect(status.exitstatus).to eq(2)
        expect(errors).
          to eq("NotLoaded: LoadError: cannot load such file -- nokogiri\n")
        expect(Dir.children(scratch)).to be_empty
      end
    end

    it 'says the file was too large when it runs out of memory' do
      run_worker(made_big, %w[excel],
                 rlimit_as: 400 * 1024 * 1024) do |status, errors, scratch|
        expect(status).not_to be_success
        expect(errors).to match(AlaveteliSandbox::OfficeStep::TOO_LARGE)
        expect(Dir.children(scratch)).to be_empty
      end
    end
  end

  context 'in bubblewrap' do
    before do
      allow(AlaveteliConfiguration).to receive(:sandbox_converters).
        and_return('required')
      problem = AlaveteliSandbox.volume_problem
      skip "the sandbox can't run here: #{problem}" if problem
      begin
        AlaveteliSandbox.self_test
      rescue AlaveteliSandbox::Error => e
        skip "the sandbox can't run here: #{e.message}"
      end
    end

    corpus.each do |name, bytes|
      it "gives what the readers in the app give for #{name}" do
        [[everything, sheets, zip_limits], [unguarded, sheets, zip_limits],
         [%w[sheets], whole_sheets, nil]].each do |sections, limits, zip|
          expect(job_left(bytes, name, sections, limits, zip)).
            to eq(in_app(bytes, sections, sheets: limits, zip: zip))
        end
      end
    end

    it 'passes its self-test, as the health check runs it' do
      expect { OfficePackage::Isolated.self_test }.not_to raise_error
    end

    it 'fails, saying why, when the worker cannot load its code' do
      allow(AlaveteliSandbox::OfficeStep).
        to receive(:gem_directories).and_return([])
      allow(Rails.logger).to receive(:warn)

      expect { OfficePackage::Isolated.self_test }.to raise_error(
        AlaveteliSandbox::Failed,
        'the Office worker failed: NotLoaded: LoadError: cannot load such ' \
        'file -- nokogiri'
      )
    end

    it 'says the file was too large when it runs out of memory' do
      stub_const('AlaveteliSandbox::OfficeStep::LIMITS',
                 AlaveteliSandbox::OfficeStep::LIMITS.
                   merge(memory: 400 * 1024 * 1024))
      allow(Rails.logger).to receive(:warn)

      expect { job_left(made_big, 'big.xlsx', %w[excel], nil) }.
        to raise_error(AlaveteliSandbox::Failed) { |error|
          expect(error.result.stderr).
            to match(AlaveteliSandbox::OfficeStep::TOO_LARGE)
        }
    end

    it 'leaves nothing on the volume' do
      OfficePackage::Isolated.self_test
      expect(Dir.children(AlaveteliSandbox.volume).grep(/\Ajob-/)).
        to be_empty
    end
  end

  context 'in an Office cell' do
    let(:dir) { Dir.mktmpdir('office-cell-spec') }
    let(:socket) { File.join(dir, 'office.sock') }
    let(:volume) { AlaveteliSandbox.volume }
    let(:pids) { [] }

    # The volume as it is with cells: its group may enter. Put back after.
    around do |example|
      mode = File.stat(volume).mode & 0o7777 if File.directory?(volume)
      File.chmod(0o710, volume) if mode && File.owned?(volume)
      example.run
    ensure
      File.chmod(mode, volume) if mode && File.owned?(volume)
    end

    before do
      allow(AlaveteliConfiguration).to receive_messages(
        sandbox_converters: 'required', sandbox_office_cell: socket,
        sandbox_pdf_cell: File.join(dir, 'no-pdf.sock'),
        sandbox_mail_cell: File.join(dir, 'no-mail.sock')
      )
      problem = AlaveteliSandbox.volume_problem
      skip "the sandbox can't run here: #{problem}" if problem
    end

    after do
      pids.each do |pid|
        Process.kill('TERM', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      FileUtils.remove_entry(dir)
    end

    def start_cell(root: Rails.root.to_s,
                   gems: AlaveteliSandbox::OfficeStep.gem_directories)
      pids << Process.spawn(
        { 'SANDBOX_CELL_KIND' => 'office', 'SANDBOX_CELL_SOCKET' => socket,
          'SANDBOX_VOLUME' => volume, 'PATH' => ENV.fetch('PATH'),
          'SANDBOX_BWRAP' => AlaveteliSandbox.bwrap,
          'SANDBOX_OFFICE_GEMS' => gems.join(':') },
        RbConfig.ruby, '--disable-gems',
        File.join(root, 'script/sandbox_cell.rb'),
        unsetenv_others: true, err: "#{socket}.err"
      )
      Timeout.timeout(60) { sleep 0.05 until File.socket?(socket) }
      AlaveteliSandbox.self_test(cell: 'office')
    rescue AlaveteliSandbox::Error => e
      skip "the sandbox can't run here: #{e.message}"
    end

    it 'gives what the readers in the app give for every file' do
      start_cell
      expect(AlaveteliSandbox::ProcessRunner).not_to receive(:new)

      differing = corpus.reject do |name, bytes|
        job_left(bytes, name, everything, sheets, zip_limits) ==
          in_app(bytes, everything, sheets: sheets, zip: zip_limits)
      end
      expect(differing.keys).to eq([])
    end

    it 'passes its self-test, as the health check runs it' do
      start_cell
      expect { OfficePackage::Isolated.self_test }.not_to raise_error
    end

    it 'leaves nothing on the volume' do
      start_cell
      OfficePackage::Isolated.self_test
      expect(Dir.children(volume).grep(/\Ajob-/)).to be_empty
    end

    # The checkout is not under /tmp, where a step sees its own empty one.
    it 'reads from a checkout that holds only the sandbox and the worker' do
      root = Dir.mktmpdir('checkout', Rails.root.join('tmp'))
      shared = Dir.glob(AlaveteliSandbox::Cell::SHARED_CODE,
                        base: Rails.root.to_s)
      (shared + AlaveteliSandbox::OfficeStep::SOURCE).each do |name|
        next unless File.file?(Rails.root.join(name))

        FileUtils.mkdir_p(File.dirname(File.join(root, name)))
        FileUtils.cp(Rails.root.join(name), File.join(root, name))
      end
      start_cell(root: root)

      bytes = corpus.fetch('interesting.xlsx')
      expect(job_left(bytes, 'interesting.xlsx', everything, sheets,
                      zip_limits)).
        to eq(in_app(bytes, everything, sheets: sheets, zip: zip_limits))
    ensure
      FileUtils.remove_entry(root)
    end

    it 'refuses a read when the cell has not been told the gems' do
      start_cell(gems: [])
      allow(Rails.logger).to receive(:warn)

      expect { OfficePackage::Isolated.self_test }.
        to raise_error(AlaveteliSandbox::Refused, /not been told/)
    end

    it 'refuses a read when the cell’s gems are not the app’s' do
      gems = AlaveteliSandbox::OfficeStep.gem_directories
      start_cell(gems: gems + [File.join(dir, 'another-1.0')])
      allow(Rails.logger).to receive(:warn)

      expect { OfficePackage::Isolated.self_test }.
        to raise_error(AlaveteliSandbox::Refused, /differ; restart the cell/)
    end
  end
end
