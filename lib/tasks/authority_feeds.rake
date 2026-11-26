namespace :authority_feeds do
  desc "Fetch regulators' new decisions for authority pages"
  task fetch: :environment do
    puts AuthorityFeeds::Fetch.run.to_json
  end
end
