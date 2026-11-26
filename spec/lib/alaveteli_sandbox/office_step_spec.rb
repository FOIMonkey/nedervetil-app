require 'spec_helper'
require 'open3'

RSpec.describe AlaveteliSandbox::OfficeStep do
  let(:gems) { described_class.gem_directories }

  # RubyGems activates Bundler if BUNDLER_SETUP is set, so scrub BUNDLE* env.
  def bare_ruby(*arguments)
    environment = (%w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH] +
                   ENV.keys.grep(/\ABUNDLE/)).to_h { |name| [name, nil] }
    Open3.capture3(environment, RbConfig.ruby, '--disable-gems', *arguments)
  end

  describe '.gem_directories' do
    it 'gives the worker’s gems and the gems those need, as the bundle ' \
       'has them' do
      names = described_class.gem_names(gems).
              map { |name| name[/\A(.+?)-\d/, 1] }
      expect(names).to include('nokogiri', 'racc', 'rubyzip', 'bigdecimal')
      expect(names).not_to include('rubyXL')
      expect(gems).to all(satisfy { |dir| File.directory?(dir) })
    end

    it 'gives the bundle’s bigdecimal, not Ruby’s own' do
      expect(gems).
        to include(*Gem.loaded_specs['bigdecimal'].full_require_paths)
    end
  end

  describe 'script/office_worker_gems' do
    it 'prints the same directories, one to a line' do
      # Without this process's bundle, as a deploy runs it.
      environment = %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE].
                    to_h { |name| [name, nil] }
      output, errors, status = Open3.capture3(
        environment, Rails.root.join('script/office_worker_gems').to_s
      )
      expect(status).to be_success, errors
      expect(output.lines(chomp: true)).to eq(gems)
    end
  end

  describe 'SOURCE' do
    # A deploy writes the cell's unit from it, with only this file loaded.
    it 'can be read by a bare Ruby that loads this file alone' do
      step = Rails.root.join('lib/alaveteli_sandbox/office_step.rb').to_s
      output, errors, status = bare_ruby(
        '-e', 'require ARGV[0]; puts AlaveteliSandbox::OfficeStep::SOURCE', step
      )
      expect(status).to be_success, errors
      expect(output.lines(chomp: true)).to eq(described_class::SOURCE)
    end

    let(:root) { Rails.root.to_s }

    def loaded
      worker = File.join(root, described_class::SOURCE.first)
      script = <<~RUBY
        load #{worker.inspect}
        puts $LOADED_FEATURES
      RUBY
      output, errors, status = bare_ruby(
        *gems.flat_map { |dir| ['-I', dir] }, '-e', script
      )
      expect(status).to be_success, errors
      output.lines(chomp: true)
    end

    it 'is every file of the app’s the worker loads, and no more' do
      files = loaded.filter_map do |file|
        file.delete_prefix("#{root}/") if file.start_with?("#{root}/")
      end
      expect(files + [described_class::SOURCE.first]).
        to match_array(described_class::SOURCE)
    end

    # RubyGems may live in site_ruby.
    it 'loads nothing else but its gems, RubyGems and Ruby’s own library' do
      allowed = gems + [root] +
                RbConfig::CONFIG.values_at('rubylibdir', 'rubyarchdir',
                                           'sitelibdir', 'sitearchdir')
      others = loaded.select do |file|
        file.start_with?('/') &&
          allowed.none? { |dir| file.start_with?("#{dir}/") }
      end
      expect(others).to eq([])
    end

    it 'names the sections the worker reads' do
      worker = Rails.root.join(described_class::SOURCE.first).to_s
      script = <<~RUBY
        load #{worker.inspect}
        puts OfficeWorker::SECTIONS, OfficeWorker::REPORT,
             OfficeWorker::STRINGS, OfficeWorker::TIDIED,
             OfficeWorker::ZIP_ENTRIES, OfficeWorker::EMBEDDED_XLS
      RUBY
      output, errors, status = bare_ruby(
        *gems.flat_map { |dir| ['-I', dir] }, '-e', script
      )
      expect(status).to be_success, errors
      expect(output.lines(chomp: true)).to eq(
        described_class::SECTIONS +
        [described_class::REPORT, described_class::STRINGS,
         described_class::TIDIED, described_class::ZIP_ENTRIES,
         described_class::EMBEDDED_XLS]
      )
    end
  end

  describe '.release' do
    let(:dir) { Dir.mktmpdir('office-step-spec') }

    after { FileUtils.remove_entry(dir) }

    def checkout(reader: 'reader')
      root = File.join(dir, SecureRandom.hex(4))
      described_class::SOURCE.each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(root, name)))
        File.write(File.join(root, name), name)
      end
      sheets = 'gems/office_package/lib/office_package/sheets.rb'
      File.write(File.join(root, sheets), reader)
      File.write(File.join(root, 'README.md'), SecureRandom.hex)
      root
    end

    let(:here) { %w[/a/gems/nokogiri-1.19.7/lib /a/gems/rubyXL-3.4.39/lib] }

    it 'is the same for the same worker and gems, wherever the gems are' do
      there = %w[/b/gems/rubyXL-3.4.39/lib /b/gems/nokogiri-1.19.7/lib]
      expect(described_class.release(checkout, here)).
        to eq(described_class.release(checkout, there))
    end

    it 'differs when the worker’s code differs' do
      expect(described_class.release(checkout, here)).
        not_to eq(described_class.release(checkout(reader: 'other'), here))
    end

    it 'differs when a gem’s version differs' do
      root = checkout
      expect(described_class.release(root, here)).not_to eq(
        described_class.release(root, %w[/a/gems/nokogiri-1.19.8/lib
                                         /a/gems/rubyXL-3.4.39/lib])
      )
    end

    it 'is not the mail worker’s, for the same checkout and gems' do
      root = checkout
      AlaveteliSandbox::MailStep::SOURCE.each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(root, name)))
        File.write(File.join(root, name), name)
      end
      expect(described_class.release(root, here)).
        not_to eq(AlaveteliSandbox::MailStep.release(root, here))
    end
  end

  describe '.arguments' do
    let(:sheets) do
      { max_rows: 2000, max_columns: 60, max_cells: 200_000,
        max_read_cells: 2_000_000 }
    end

    it 'gives the sections in the order the worker reads them' do
      expect(described_class.arguments(%w[tidy guard hidden], nil)).
        to eq(['guard,hidden,tidy'])
    end

    it 'gives the sheets section’s limits after the sections, none for no ' \
       'limit' do
      expect(described_class.arguments(%w[sheets guard], sheets)).
        to eq(%w[guard,sheets 2000 60 200000 2000000])
      whole = sheets.merge(max_rows: nil, max_columns: nil)
      expect(described_class.arguments(%w[sheets], whole)).
        to eq(%w[sheets none none 200000 2000000])
      expect(described_class.arguments(%w[sheets], sheets.stringify_keys)).
        to eq(%w[sheets 2000 60 200000 2000000])
    end

    it 'refuses sections that aren’t some of SECTIONS, each once' do
      [[], %w[guard guard], %w[shell], ['guard,hidden'], 'guard', nil,
       [nil], [1]].each do |sections|
        expect { described_class.arguments(sections, nil) }.
          to raise_error(ArgumentError, /sections must be some of/)
      end
    end

    it 'refuses sheet limits without the sheets section, and the sheets ' \
       'section without them' do
      expect { described_class.arguments(%w[guard], sheets) }.
        to raise_error(ArgumentError, /sheets section only/)
      expect { described_class.arguments(%w[sheets], nil) }.
        to raise_error(ArgumentError, /needs max_rows/)
      expect do
        described_class.arguments(%w[sheets], sheets.except(:max_cells))
      end.to raise_error(ArgumentError, /needs max_rows/)
      expect do
        described_class.arguments(%w[sheets], sheets.merge(depth: 1))
      end.to raise_error(ArgumentError, /needs max_rows/)
    end

    it 'refuses limits out of range or that aren’t whole numbers' do
      most = described_class::SHEET_LIMITS
      [{ max_rows: 0 }, { max_rows: most[:max_rows] + 1 },
       { max_columns: '60' }, { max_columns: 1.5 }, { max_cells: nil },
       { max_read_cells: most[:max_read_cells] + 1 }, { max_cells: true },
       { max_read_cells: -1 }].each do |bad|
        expect { described_class.arguments(%w[sheets], sheets.merge(bad)) }.
          to raise_error(ArgumentError, /must be from 1 to/)
      end
    end

    it 'allows what the app asks of OfficePackage::Sheets' do
      app = { max_rows: Disclosures.sheet_max_rows,
              max_columns: Disclosures.sheet_max_columns,
              max_cells: Disclosures::Sheets::MAX_CELLS,
              max_read_cells: Disclosures::Sheets::MAX_READ_CELLS }
      expect { described_class.arguments(%w[sheets], app) }.not_to raise_error
    end

    it 'accepts zip_entries limits and refuses bad or stray zip limits' do
      zip = { max_entries: AttachmentToText::MAX_ZIP_ENTRIES,
              max_entry: AttachmentToText::MAX_ZIP_ENTRY,
              max_total: AttachmentToText::MAX_ZIP_TOTAL }
      expect(described_class.arguments(%w[zip_entries guard], nil, zip)).
        to eq(['guard,zip_entries', zip[:max_entries].to_s,
               zip[:max_entry].to_s, zip[:max_total].to_s])
      expect(
        described_class.arguments(%w[zip_entries], nil, zip.merge(skip: 2))
      ).to eq(['zip_entries', zip[:max_entries].to_s, zip[:max_entry].to_s,
               zip[:max_total].to_s, '2'])
      expect(described_class.arguments(%w[sheets zip_entries], sheets, zip)).
        to eq(['sheets,zip_entries', '2000', '60', '200000', '2000000',
               zip[:max_entries].to_s, zip[:max_entry].to_s,
               zip[:max_total].to_s])

      expect { described_class.arguments(%w[guard], nil, zip) }.
        to raise_error(ArgumentError, /zip_entries section only/)
      expect { described_class.arguments(%w[zip_entries], nil, nil) }.
        to raise_error(ArgumentError, /needs max_entries/)
      expect do
        described_class.arguments(
          %w[zip_entries], nil, zip.merge(max_entries: 0)
        )
      end.to raise_error(ArgumentError, /must be from 1 to/)
      expect do
        described_class.arguments(
          %w[zip_entries], nil,
          zip.merge(max_total: described_class::ZIP_LIMITS[:max_total] + 1)
        )
      end.to raise_error(ArgumentError, /must be from 1 to/)
    end
  end

  describe '.command' do
    let(:built) do
      described_class.command(
        bwrap: '/usr/bin/bwrap', input_dir: '/volume/job-1/in',
        scratch_dir: '/volume/job-1/scratch', input_name: 'file.xlsx',
        limits: given, runtime: '/usr/local', ruby: '/usr/local/bin/ruby',
        root: '/srv/app',
        gem_directories: %w[/gems/nokogiri-1.19.7/lib /gems/rubyzip-3.7.0/lib],
        sections: sections, sheets: sheets
      )
    end
    let(:given) do
      AlaveteliSandbox::Job::STEP_DEFAULTS.merge(timeout: 600, memory: 1024)
    end
    let(:sections) { %w[strings guard] }
    let(:sheets) { nil }
    let(:argv) { built.first }

    it 'starts the worker with a Ruby that looks for no gems, given its ' \
       'gems’ directories' do
      expect(argv.last(10)).to eq(
        ['/usr/local/bin/ruby', '--disable-gems',
         '-I', '/gems/nokogiri-1.19.7/lib', '-I', '/gems/rubyzip-3.7.0/lib',
         '/srv/app/script/office_worker.rb', '/volume/job-1/in/file.xlsx',
         '/volume/job-1/scratch', 'guard,strings']
      )
    end

    context 'with the sheets section' do
      let(:sections) { %w[sheets] }
      let(:sheets) do
        { max_rows: nil, max_columns: 60, max_cells: 10, max_read_cells: 20 }
      end

      it 'gives the worker its limits' do
        expect(argv.last(5)).to eq(%w[sheets none 60 10 20])
      end
    end

    it 'refuses sections the worker doesn’t read' do
      expect do
        described_class.command(
          bwrap: '/usr/bin/bwrap', input_dir: '/i', scratch_dir: '/s',
          input_name: 'f', limits: given, runtime: '/usr', ruby: '/usr/ruby',
          root: '/srv/app', gem_directories: [], sections: %w[--help],
          sheets: nil
        )
      end.to raise_error(ArgumentError)
    end

    it 'shows the worker its source and its gems, and nothing else of ' \
       'the app' do
      shown = argv.each_cons(3).filter_map do |flag, from, to|
        from if flag == '--ro-bind' && from == to
      end
      source = described_class::SOURCE.map { |name| "/srv/app/#{name}" }
      expect(shown).to match_array(
        ['/usr', *source, '/gems/nokogiri-1.19.7/lib',
         '/gems/rubyzip-3.7.0/lib', '/volume/job-1/in']
      )
    end

    it 'runs under the worker’s limits, whatever the step was given' do
      limits = described_class::LIMITS
      expect(built.last).to include(limits)
      expect(argv).to include("--as=#{limits[:memory]}",
                              "--nproc=#{limits[:processes]}",
                              "--cpu=#{limits[:timeout]}",
                              "--fsize=#{limits[:file_size]}")
    end

    context 'given less time than the worker’s own limit' do
      let(:given) { AlaveteliSandbox::Job::STEP_DEFAULTS.merge(timeout: 15) }

      it 'runs for no longer than it was given' do
        expect(built.last).to include(described_class::LIMITS.
                                      merge(timeout: 15))
      end
    end

    it 'asks for no more than a cell allows' do
      most = AlaveteliSandbox::CellServer::MOST
      described_class::LIMITS.each do |limit, value|
        expect(value).to be <= most.fetch(limit)
      end
    end
  end
end
