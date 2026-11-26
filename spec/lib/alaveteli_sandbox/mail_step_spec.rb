require 'spec_helper'
require 'open3'

RSpec.describe AlaveteliSandbox::MailStep do
  let(:gems) { described_class.gem_directories }

  # A bare Ruby, as the worker is started.
  def bare_ruby(*arguments)
    environment = %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE].
                  to_h { |name| [name, nil] }
    Open3.capture3(environment, RbConfig.ruby, '--disable-gems', *arguments)
  end

  describe '.gem_directories' do
    it 'gives the worker’s gems and the gems those need, as the bundle ' \
       'has them' do
      names = described_class.gem_names(gems).
              map { |name| name[/\A(.+)-[\d.]+\z/, 1] }
      expect(names).to include(
        'mail', 'mini_mime', 'net-smtp', 'net-imap', 'net-pop',
        'net-protocol', 'timeout', 'date', 'charlock_holmes', 'marcel'
      )
      expect(gems).to all(satisfy { |dir| File.directory?(dir) })
    end

    # Gems that come with Ruby share its directories.
    it 'gives each directory once, when two gems share one' do
      shared = Struct.new(:full_require_paths, :runtime_dependencies)
      allow(Gem).to receive(:loaded_specs).and_return(
        'mail' => shared.new(%w[/ruby/lib /ruby/lib/arch], []),
        'marcel' => shared.new(%w[/ruby/lib /gems/marcel-1.0.4/lib], []),
        'charlock_holmes' => shared.new(%w[/ruby/lib/arch], [])
      )

      expect(described_class.gem_directories).
        to eq(%w[/ruby/lib /ruby/lib/arch /gems/marcel-1.0.4/lib])
    end

    it 'gives the versions this process has loaded' do
      expect(gems).to include(Gem.loaded_specs['mail'].full_require_paths[0])
    end

    it 'gives the directory of a gem’s compiled code as well as its Ruby' do
      compiled = gems.select do |dir|
        Dir.glob('**/*.{so,bundle}', base: dir).any?
      end
      expect(compiled.map { |dir| File.basename(dir)[/\A[a-z_]+/] }).
        to include('charlock_holmes', 'date')
    end
  end

  describe 'script/mail_worker_gems' do
    it 'prints the same directories, one to a line' do
      # Without this process's bundle, as a deploy runs it.
      environment = %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE].
                    to_h { |name| [name, nil] }
      output, errors, status = Open3.capture3(
        environment, Rails.root.join('script/mail_worker_gems').to_s
      )
      expect(status).to be_success, errors
      expect(output.lines(chomp: true)).to eq(gems)
    end
  end

  describe 'SOURCE' do
    # A deploy writes the cell's unit from it, with only this file loaded.
    it 'can be read by a bare Ruby that loads this file alone' do
      step = Rails.root.join('lib/alaveteli_sandbox/mail_step.rb').to_s
      output, errors, status = bare_ruby(
        '-e', 'require ARGV[0]; puts AlaveteliSandbox::MailStep::SOURCE', step
      )
      expect(status).to be_success, errors
      expect(output.lines(chomp: true)).to eq(described_class::SOURCE)
    end

    it 'is every file of the app’s the worker loads, and no more' do
      root = Rails.root.to_s
      worker = File.join(root, described_class::SOURCE.first)
      script = <<~RUBY
        load #{worker.inspect}
        puts $LOADED_FEATURES.select { |f| f.start_with?(#{root.inspect}) }
      RUBY
      output, errors, status = bare_ruby(
        *gems.flat_map { |dir| ['-I', dir] }, '-e', script
      )
      expect(status).to be_success, errors

      loaded = output.lines(chomp: true).map do |file|
        file.delete_prefix("#{root}/")
      end
      expect(loaded + [described_class::SOURCE.first]).
        to match_array(described_class::SOURCE)
    end
  end

  describe '.release' do
    let(:dir) { Dir.mktmpdir('mail-step-spec') }

    after { FileUtils.remove_entry(dir) }

    def checkout(walk: 'walk')
      root = File.join(dir, SecureRandom.hex(4))
      described_class::SOURCE.each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(root, name)))
        File.write(File.join(root, name), name)
      end
      File.write(File.join(root, 'lib/mail_handler/parts.rb'), walk)
      File.write(File.join(root, 'README.md'), SecureRandom.hex)
      root
    end

    it 'is the same for the same worker and gems, wherever the gems are' do
      here = %w[/a/gems/mail-2.9.1/lib /a/extensions/x/3.4.0/date-3.6.0]
      there = %w[/b/extensions/y/3.4.0/date-3.6.0 /b/gems/mail-2.9.1/lib]

      expect(described_class.release(checkout, here)).
        to eq(described_class.release(checkout, there))
    end

    it 'differs when the worker’s code differs' do
      expect(described_class.release(checkout, %w[/a/gems/mail-2.9.1/lib])).
        not_to eq(described_class.release(checkout(walk: 'other'),
                                          %w[/a/gems/mail-2.9.1/lib]))
    end

    it 'differs when a gem’s version differs' do
      root = checkout
      expect(described_class.release(root, %w[/a/gems/mail-2.9.1/lib])).
        not_to eq(described_class.release(root, %w[/a/gems/mail-2.9.2/lib]))
    end

    it 'differs when the gems aren’t known' do
      root = checkout
      expect(described_class.release(root, %w[/a/gems/mail-2.9.1/lib])).
        not_to eq(described_class.release(root, []))
    end
  end

  describe '.gem_names' do
    it 'takes each gem’s name and version from its directories' do
      expect(
        described_class.gem_names(
          %w[/opt/ruby-3.4.13/gems/3.4.0/gems/mail-2.9.1/lib
             /b/vendor/ruby/3.4.0/gems/date-3.6.0/lib
             /b/vendor/ruby/3.4.0/extensions/aarch64-linux/3.4.0/date-3.6.0]
        )
      ).to eq(%w[date-3.6.0 mail-2.9.1])
    end
  end

  describe '.command' do
    let(:built) do
      described_class.command(
        bwrap: '/usr/bin/bwrap', input_dir: '/volume/job-1/in',
        scratch_dir: '/volume/job-1/scratch', input_name: 'mail.eml',
        limits: given, runtime: '/usr/local',
        ruby: '/usr/local/bin/ruby', root: '/srv/app',
        gem_directories: %w[/gems/mail-2.9.1/lib /gems/date-3.6.0],
        tools: tools, bodies: bodies, stored: stored
      )
    end
    let(:given) do
      AlaveteliSandbox::Job::STEP_DEFAULTS.merge(timeout: 600, memory: 1024)
    end
    let(:stored) { false }
    let(:tools) { true }
    let(:bodies) { 'all' }
    let(:argv) { built.first }

    it 'starts the worker with a Ruby that looks for no gems, given its ' \
       'gems’ directories' do
      expect(argv.last(11)).to eq(
        ['/usr/local/bin/ruby', '--disable-gems',
         '-I', '/gems/mail-2.9.1/lib', '-I', '/gems/date-3.6.0',
         '/srv/app/script/mail_worker.rb', '/volume/job-1/in/mail.eml',
         '/volume/job-1/scratch', '1', 'all']
      )
    end

    context 'with converters switched off' do
      let(:tools) { false }

      it 'tells the worker to run no tools' do
        expect(argv.last(2)).to eq(%w[0 all])
      end
    end

    context 'when one part’s bytes are wanted' do
      let(:bodies) { 'd41d8cd98f00b204e9800998ecf8427e' }

      it 'tells the worker which' do
        expect(argv.last).to eq('d41d8cd98f00b204e9800998ecf8427e')
      end
    end

    context 'with a stored file to match' do
      let(:stored) { true }

      it 'names it, in the scratch area' do
        expect(argv.last).to eq('/volume/job-1/scratch/stored')
      end
    end

    it 'shows the worker its source and its gems, and nothing else of ' \
       'the app' do
      shown = argv.each_cons(3).filter_map do |flag, from, to|
        from if flag == '--ro-bind' && from == to
      end
      source = described_class::SOURCE.map { |name| "/srv/app/#{name}" }
      expect(shown).to match_array(
        ['/usr', *source, '/gems/mail-2.9.1/lib', '/gems/date-3.6.0',
         '/volume/job-1/in']
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

      it 'runs for no longer than it was given, under the worker’s other ' \
         'limits' do
        limits = described_class::LIMITS.merge(timeout: 15)
        expect(built.last).to include(limits)
        expect(argv).to include("--as=#{limits[:memory]}", '--cpu=15')
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
