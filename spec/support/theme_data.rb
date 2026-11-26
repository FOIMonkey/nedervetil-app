# Themes supply the app's optional data; specs use their own small set.
Rails.configuration.paths.add('data', with: 'spec/fixtures/data')

# Pages read topics from the tables, so the sample topics are written once,
# committed, outside every example's transaction. The tables are emptied
# first, so they hold the sample as it is now, not as an earlier run left it.
RSpec.configure do |config|
  config.before(:suite) do
    next unless defined?(TopicPage)

    [TopicHolder, TopicQuestion, TopicSource, TopicRoute, TopicPage,
     TopicDataset, TopicChange].each(&:delete_all)
    SampleData::Topics.load!
  end
end
