namespace :topics do
  desc 'Write the HTML of every page that reads topic data into DIR, one ' \
       'file per address, to compare before and after moving topic content'
  task :capture, [:dir] => :environment do |_task, args|
    dir = Pathname(args.fetch(:dir))
    dir.mkpath
    urls = TopicsCapture.urls
    urls.each do |url|
      file = dir.join(TopicsCapture.file_name(url))
      raise "#{url} and another address share #{file}" if file.exist?

      file.write(TopicsCapture.render(url))
    end
    puts "topics:capture: #{urls.size} addresses written to #{dir}"
  end
end

# Renders topic-dependent pages into normalized HTML snapshots for diffing.
module TopicsCapture
  module_function

  def urls
    paths = Rails.application.routes.url_helpers
    topics = Topics::Topic.all
    nations = Topics::Topic::NATIONS.keys
    place = ->(nation) { nation unless nation == 'england' }
    first = topics.first.slug

    ['/', paths.topics_path, paths.topics_path(step: 'own'),
     paths.topics_path(step: 'fix'),
     paths.topic_path(first, step: 'q-0'),
     paths.topic_path(first, view: 'all')] +
      topics.product(nations).flat_map do |topic, nation|
        [paths.topic_path(topic.slug, nation: place[nation]),
         paths.topic_holders_path(topic.slug, nation: place[nation])] +
          Topics::Guide.new(topic, nation).entries.map do |entry|
            paths.topic_question_path(topic.slug, entry.slug,
                                      nation: place[nation])
          end
      end +
      PublicBody.order(:url_name).pluck(:url_name).map do |name|
        paths.show_public_body_path(url_name: name)
      end +
      [paths.authority_groups_path] +
      AuthorityGroups::Group.headings.values.
        flat_map { |heading| AuthorityGroups::Group.listing(heading).to_a }.
        map { |group| paths.authority_group_path(group.category_tag) } +
      [paths.disclosure_documents_path] +
      topics.select(&:search).map do |topic|
        paths.disclosure_documents_path(topic: topic.slug)
      end
  end

  def file_name(url)
    name = url.delete_prefix('/').gsub(/[^A-Za-z0-9._=-]/, '_')
    "#{name.presence || 'index'}.html"
  end

  # A fresh session each time, so no cookie or flash carries between pages.
  def render(url)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! 'localhost'
    session.get(url)
    response = session.response
    location = response.location && "Location: #{response.location}\n"
    "Status: #{response.status}\n#{location}\n#{normalise(response.body)}"
  end

  # Only what changes between two renders of the same code and data.
  def normalise(html)
    html.
      gsub(/(<meta name="csrf-token" content=")[^"]*/, '\1CSRF').
      gsub(/(name="authenticity_token" value=")[^"]*/, '\1CSRF').
      gsub(/( nonce=")[^"]*/, '\1NONCE').
      gsub(/(<meta name="csp-nonce" content=")[^"]*/, '\1NONCE').
      gsub(%r{(<p class="print-information">.*? on ).*?(</p>)}, '\1TIME\2')
  end
end
