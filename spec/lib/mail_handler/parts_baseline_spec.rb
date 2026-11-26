require 'spec_helper'

# Stored attachments match email parts by digest, number, name, and type, so
# parse drift orphans stored files. Compare against mail_parts_baseline.json.
#
# Regenerate only when stored mail is meant to parse differently:
#   RECORD_MAIL_PARTS_BASELINE=1 bundle exec rspec \
#     spec/lib/mail_handler/parts_baseline_spec.rb
RSpec.describe 'What the walk makes of each email fixture' do
  baseline_path = Rails.root.join('spec/fixtures/mail_parts_baseline.json')
  fixtures = Dir[Rails.root.join('spec/fixtures/files/*.eml')]

  def describe_fixture(path)
    MailPartsDescription.of(File.binread(path)) do |raw|
      Mail.from_source(raw)
    end
  end

  if ENV['RECORD_MAIL_PARTS_BASELINE']
    it 'is recorded' do
      recorded = fixtures.to_h do |path|
        [File.basename(path), describe_fixture(path)]
      end
      File.write(baseline_path, "#{JSON.pretty_generate(recorded)}\n")
    end
  else
    baseline = JSON.parse(File.read(baseline_path, encoding: 'UTF-8'))

    it 'has a baseline for every fixture and no others' do
      expect(baseline.keys).to eq(fixtures.map { |path| File.basename(path) })
    end

    fixtures.each do |path|
      name = File.basename(path)

      it "is unchanged for #{name}" do
        described = JSON.parse(JSON.generate(describe_fixture(path)))
        expect(described).to eq(baseline.fetch(name))
      end
    end
  end
end
