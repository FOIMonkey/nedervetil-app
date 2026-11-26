# Enforces UI copy rules on templates and TopicPage data. Ratcheted rules only
# fail on new findings; run with COPY_RULES_UPDATE=1 to update the baseline.
module CopyRules
  RATCHET = %i[long_buttons long_links placeholders].freeze

  def self.findings(templates:, topics: [], relative: ->(path) { path })
    words = ->(text) { text.split.size }

    found = Hash.new { |hash, key| hash[key] = [] }
    templates.each do |path|
      source = File.read(path)
      name = relative.call(path)
      template = Template.new(source)
      text = template.text
      if text.match?(/\w!/)
        found[:exclamations] << "#{name}: #{text[/[^.?!\n]*!/].to_s.squish}"
      end
      found[:cute] << name if text.match?(/\b(oops|whoops|uh oh)\b/i)
      template.labels('link_to').each do |label|
        if label.match?(/\A(here|click here|more|read more|this|link)\z/i)
          found[:vague_links] << "#{name}: #{label}"
        end
      end
      source.scan(%r{>\s*(here|click here|read more)\s*</a>}i) do
        found[:vague_links] << "#{name}: #{Regexp.last_match(1)}"
      end
      source.scan(
        # rubocop:disable Layout/LineLength
        /placeholder(?:=|:\s*)["']((?:Enter|Type|Search|Find|Add|Write)\b[^"']*)["']/
        # rubocop:enable Layout/LineLength
      ) do
        found[:placeholders] << "#{name}: #{Regexp.last_match(1)}"
      end
      template.labels('submit_tag', 'button_tag', 'button_to', 'submit').
        each do |label|
          label = label.squish
          found[:long_buttons] << "#{name}: #{label}" if words.call(label) > 3
        end
      source.scan(%r{<button[^>]*>([^<]+)</button>}) do
        label = Regexp.last_match(1).squish
        found[:long_buttons] << "#{name}: #{label}" if words.call(label) > 3
      end
      template.labels('link_to').each do |label|
        label = label.squish
        found[:long_links] << "#{name}: #{label}" if words.call(label) > 4
      end
    end

    topic_fields = %w[title summary]
    topics.each do |page|
      name = page.slug
      data = page.data
      rows = topic_fields.map { |key| [key, data[key]] } +
             Array(data['published']).map { |row| ['label', row['label']] } +
             Array(data['questions']).filter_map { |row|
               if row['published_label']
                 ['published_label', row['published_label']]
               end
             } +
             Array(data['elsewhere']).map { |row| ['route', row['route']] }
      rows.each do |key, value|
        if value.to_s.end_with?('.')
          found[:full_stops] << "#{name}: #{key} #{value}"
        end
        found[:exclamations] << "#{name}: #{value}" if value.to_s.include?('!')
      end
      Array(data['elsewhere']).select { |row| row['to'] }.each do |row|
        if words.call(row['route'].to_s) > 4
          found[:long_links] << "#{name}: #{row['route']}"
        end
      end
    end
    found
  end

  def self.templates(paths)
    paths.sort.reject do |path|
      path.include?('_mailer/') || path.end_with?('.text.erb') ||
        path.include?('/admin')
    end
  end
end

# Without a baseline file every finding fails; a baseline path that doesn't
# exist is an error rather than an empty baseline.
RSpec.shared_examples 'the copy rules' do |found, baseline_file = nil|
  if baseline_file && ENV['COPY_RULES_UPDATE']
    File.write(baseline_file,
               CopyRules::RATCHET.
                 to_h { |rule| [rule.to_s, found[rule].uniq.sort] }.to_yaml)
  end
  baseline = baseline_file ? YAML.safe_load_file(baseline_file) : {}

  it 'has no exclamation marks' do
    expect(found[:exclamations]).to eq([])
  end

  it 'is never cute' do
    expect(found[:cute]).to eq([])
  end

  it 'never links "here" or "more"' do
    expect(found[:vague_links]).to eq([])
  end

  it 'ends no title, summary, label or route in a full stop (topic pages)' do
    expect(found[:full_stops]).to eq([])
  end

  CopyRules::RATCHET.each do |rule|
    it "adds no new #{rule.to_s.tr('_', ' ')} (buttons 3 words, links 4, hint text an example)" do
      expect(found[rule].uniq.sort - Array(baseline[rule.to_s])).to eq([])
    end
  end
end
