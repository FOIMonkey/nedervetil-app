require 'spec_helper'
require 'open3'

# Runs MailHandler::Parts in a bare Ruby subprocess (walk_without_rails.rb)
# with --disable-gems and compares against mail_parts_baseline.json.
RSpec.describe 'The walk, loaded without Rails' do
  baseline = JSON.parse(
    File.read(Rails.root.join('spec/fixtures/mail_parts_baseline.json'),
              encoding: 'UTF-8')
  )

  def gem_directories(names, found = {})
    names.each do |name|
      next if found.key?(name)

      spec = Gem.loaded_specs.fetch(name)
      found[name] = spec.full_require_paths
      gem_directories(spec.runtime_dependencies.map(&:name), found)
    end
    found.values.flatten
  end

  before(:context) do
    load_path = gem_directories(%w[mail charlock_holmes marcel]) +
                [Rails.root.join('lib').to_s,
                 Rails.root.join('gems/office_package/lib').to_s]
    environment = %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE].
                  to_h { |name| [name, nil] }
    output, errors, status = Open3.capture3(
      environment, RbConfig.ruby, '--disable-gems',
      *load_path.flat_map { |dir| ['-I', dir] },
      Rails.root.join('spec/lib/mail_handler/walk_without_rails.rb').to_s,
      Rails.root.join('spec/fixtures/files').to_s
    )
    @failure = "exit #{status.exitstatus}: #{errors.lines.first(5).join}"
    @result = JSON.parse(output) if status.success?
  end

  it 'runs' do
    expect(@result).not_to be_nil, @failure
  end

  it 'loads nothing of Rails, Nokogiri or RubyGems' do
    expect(@result&.fetch('rails')).to eq([])
  end

  it 'loads only these files of the app' do
    expect(@result&.fetch('loaded')).to contain_exactly(
      'lib/mail_handler/parts.rb',
      'lib/mail_handler/mail_extensions.rb',
      'lib/alaveteli_file_types.rb',
      'lib/normalize_string.rb',
      'gems/office_package/lib/office_package/error.rb',
      'gems/office_package/lib/office_package/compound_file.rb',
      'spec/support/mail_parts_description.rb'
    )
  end

  baseline.each do |name, expected|
    it "gives what the walk in the app gives for #{name}" do
      expect(@result&.dig('fixtures', name)).to eq(expected)
    end
  end
end
