require 'spec_helper'

RSpec.describe 'Copy rules' do
  # Upstream's templates that the fork hasn't changed since
  # base-production-core are skipped. A template changed later stays skipped
  # while it is on the list. To rebuild the list:
  #   git ls-files 'app/views/*.erb' | while read f; do
  #     git cat-file -e "base-production-core:$f" 2>/dev/null &&
  #       git diff --quiet base-production-core HEAD -- "$f" && echo "$f"
  #   done > spec/fixtures/files/copy_rules/upstream_untouched.txt
  skipped = File.readlines(
    Rails.root.join('spec/fixtures/files/copy_rules/upstream_untouched.txt'),
    chomp: true
  ).to_set
  relative = ->(path) { path.delete_prefix("#{Rails.root}/") }
  views = Dir[Rails.root.join('app/views/**/*.erb').to_s].
    reject { |path| skipped.include?(relative.call(path)) }
  document_admin_views = views.select do |path|
    relative.call(path).start_with?('app/views/admin/disclosures/')
  end
  templates = CopyRules.templates(views) | document_admin_views
  found = CopyRules.findings(templates: templates,
                             topics: SampleData::Topics.pages,
                             relative: relative)
  include_examples 'the copy rules', found,
                   Rails.root.join('spec/fixtures/files/copy_rules/' \
                                   'baseline.yml').to_s
end
