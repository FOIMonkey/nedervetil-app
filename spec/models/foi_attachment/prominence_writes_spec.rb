require 'spec_helper'
require 'prism'

# Static check on call sites; cannot see a hash built on an earlier line.
RSpec.describe 'Writes of prominence that skip callbacks' do
  let(:home) { 'app/models/foi_attachment/prominence.rb' }

  def skipping_writes(source)
    lines = []
    nodes = [Prism.parse(source).value]
    while (node = nodes.shift)
      nodes.concat(node.compact_child_nodes)
      lines << node.location.start_line if skipping_write?(node)
    end
    lines.sort
  end

  def skipping_write?(node)
    node.is_a?(Prism::CallNode) &&
      %i[update_columns update_column update_all].include?(node.name) &&
      node.arguments&.slice.to_s.match?(/\bprominence\b/)
  end

  def writes_by_file
    # A theme installed in lib/themes is another repository's code.
    paths = Dir[Rails.root.join('{app,lib}/**/*.{rb,rake}')].
            reject { |path| path.include?('/lib/themes/') }
    paths.to_h do |path|
      [path.delete_prefix("#{Rails.root}/"), skipping_writes(File.read(path))]
    end
  end

  it 'finds a write on one line' do
    source = "file.update_columns(prominence: 'public', updated_at: now)"
    expect(skipping_writes(source)).to eq([1])
  end

  it 'finds a write whose columns are on later lines' do
    source = <<~RUBY
      def hide(file)
        file.update_columns(
          erased_at: now,
          prominence: 'hidden'
        )
      end
    RUBY
    expect(skipping_writes(source)).to eq([2])
  end

  it 'finds update_column and update_all' do
    source = <<~RUBY
      file.update_column :prominence, 'public'
      FoiAttachment.where(id: ids).update_all(prominence: 'hidden')
      FoiAttachment.update_all("prominence = 'hidden'")
    RUBY
    expect(skipping_writes(source)).to eq([1, 2, 3])
  end

  it 'passes over other columns and saves that run callbacks' do
    source = <<~RUBY
      file.update_columns(prominence_reason: 'Checked', black_masked: true)
      file.update!(prominence: 'hidden')
      file.prominence = 'hidden'
    RUBY
    expect(skipping_writes(source)).to be_empty
  end

  it 'finds the writes in their home' do
    expect(writes_by_file.fetch(home)).not_to be_empty
  end

  it 'finds none anywhere else' do
    elsewhere = writes_by_file.except(home).flat_map do |path, lines|
      lines.map { |line| "#{path}:#{line}" }
    end
    expect(elsewhere).to be_empty, <<~MESSAGE
      These write prominence with update_columns, update_column or update_all:
        #{elsewhere.join("\n  ")}
      For a file, call one of the methods in #{home}, or add
      one there. That is the one place to read who can see a file.
    MESSAGE
  end
end
