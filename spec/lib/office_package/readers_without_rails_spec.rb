require 'spec_helper'
require 'open3'

# Runs OfficePackage readers in a bare Ruby subprocess (read_without_rails.rb)
# with only nokogiri/rubyzip/bigdecimal and compares against in-app readers.
RSpec.describe 'The Office readers, loaded without Rails' do
  def gem_directories(names, found = {})
    names.each do |name|
      next if found.key?(name)

      spec = Gem.loaded_specs.fetch(name)
      found[name] = spec.full_require_paths
      gem_directories(spec.runtime_dependencies.map(&:name), found)
    end
    found.values.flatten
  end

  def as_json(data)
    JSON.parse(JSON.generate(data), symbolize_names: true)
  end

  def in_app(path)
    as_json(
      OfficeReaderDescription.of(path,
                                 max_rows: Disclosures.sheet_max_rows,
                                 max_columns: Disclosures.sheet_max_columns)
    )
  end

  corpus = OfficeReaderCorpus.files

  before(:context) do
    @dir = Dir.mktmpdir('office-readers-')
    corpus.each { |name, bytes| File.binwrite(File.join(@dir, name), bytes) }
    @load_path = gem_directories(%w[nokogiri rubyzip bigdecimal]) +
                 [Rails.root.join('gems/office_package/lib').to_s]
    # RubyGems sets Bundler up as it loads if BUNDLER_SETUP is set.
    environment = (%w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH] +
                   ENV.keys.grep(/\ABUNDLE/)).to_h { |name| [name, nil] }
    output, errors, status = Open3.capture3(
      environment, RbConfig.ruby, '--disable-gems',
      *@load_path.flat_map { |dir| ['-I', dir] },
      Rails.root.join('spec/lib/office_package/read_without_rails.rb').to_s,
      @dir, Disclosures.sheet_max_rows.to_s,
      Disclosures.sheet_max_columns.to_s
    )
    @failure = "exit #{status.exitstatus}: #{errors.lines.first(5).join}"
    @result = JSON.parse(output, symbolize_names: true) if status.success?
  end

  after(:context) { FileUtils.remove_entry(@dir) }

  def inspector_findings(answers)
    failed = answers.values_at(:guard, :inspector).
             find { |answer| !answer.key?(:value) }
    unless failed
      return answers.dig(:inspector, :value).map do |finding|
        AttachmentManagement::OfficeInspector.label(finding)
      end
    end

    if failed.key?(:refused) || failed[:error] == 'OfficePackage::Refused'
      ['Too large or too complex to open here, so its hidden content ' \
       'could not be listed.']
    else
      ['Not an Office Open XML file, so its hidden content could not be ' \
       'listed.']
    end
  end

  def path(name)
    File.join(@dir, name)
  end

  def bare(name)
    @result&.dig(:files, name.to_sym)
  end

  it 'runs' do
    expect(@result).not_to be_nil, @failure
  end

  it 'loads nothing of Rails or Bundler' do
    expect(@result&.fetch(:rails)).to eq([])
  end

  it 'loads only these files of the app' do
    root = "#{Rails.root}/"
    loaded = @result&.fetch(:loaded)&.filter_map do |file|
      file.delete_prefix(root) if file.start_with?(root)
    end
    expect(loaded).to contain_exactly(
      'gems/office_package/lib/office_package.rb',
      'gems/office_package/lib/office_package/error.rb',
      'gems/office_package/lib/office_package/archive.rb',
      'gems/office_package/lib/office_package/package.rb',
      'gems/office_package/lib/office_package/guard.rb',
      'gems/office_package/lib/office_package/inspector.rb',
      'gems/office_package/lib/office_package/sheets.rb',
      'spec/support/office_reader_description.rb'
    )
  end

  # RubyGems may be a newer one, in site_ruby.
  it 'loads nothing else but those gems, RubyGems and Ruby’s own library' do
    allowed = @load_path + [Rails.root.join('spec/support').to_s] +
              RbConfig::CONFIG.values_at('rubylibdir', 'rubyarchdir',
                                         'sitelibdir', 'sitearchdir')
    others = @result&.fetch(:loaded)&.select do |file|
      file.start_with?('/') &&
        allowed.none? { |dir| file.start_with?("#{dir}/") }
    end
    expect(others).to eq([])
  end

  it 'holds a zip to the limits the app’s ZipGuard has' do
    expect(@result&.fetch(:limits)).to eq(as_json(OfficePackage.limits))
    expect(OfficePackage.limits).to eq(
      entries: AttachmentManagement::ZipGuard::MAX_ENTRIES,
      total: AttachmentManagement::ZipGuard::MAX_TOTAL,
      ratio: AttachmentManagement::ZipGuard::MAX_RATIO,
      ratio_from: AttachmentManagement::ZipGuard::RATIO_FROM,
      xml_part: AttachmentManagement::ZipGuard::MAX_PART
    )
  end

  corpus.each_key do |name|
    describe name do
      it 'gives what the readers in the app give' do
        expect(bare(name)).to eq(in_app(path(name)))
      end

      it 'is what the app’s ZipGuard decides' do
        guard = bare(name)&.fetch(:guard)
        check = -> { AttachmentManagement::ZipGuard.check!(path(name)) }
        if guard&.key?(:refused)
          refusal = OfficePackage::Guard::Refused.new(guard[:refused],
                                                      **guard[:values])
          expect(&check).to raise_error(
            AttachmentManagement::ZipGuard::Refused,
            AttachmentManagement::ZipGuard.refused(refusal).message
          )
        elsif guard&.key?(:error)
          expect(&check).to raise_error(guard[:error].constantize,
                                        guard[:message])
        else
          expect(check.call).to be(guard&.fetch(:value))
        end
      end

      it 'is what the app’s OfficeInspector lists' do
        expect(AttachmentManagement::OfficeInspector.findings(path(name))).
          to eq(inspector_findings(bare(name) || {}))
      end

      it 'is what the app’s Sheets shows' do
        read = -> { Disclosures::Sheets.read_xlsx(path(name)).map(&:to_h) }
        answers = bare(name)
        if answers&.dig(:guard, :value) && answers.dig(:sheets, :value)
          expect(read.call).to eq(answers.dig(:sheets, :value))
        else
          expect(&read).to raise_error(Disclosures::Error::Refused)
        end
      end
    end
  end
end
