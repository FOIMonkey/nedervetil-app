# Checks referential integrity across TopicPage, TopicDataset, and TopicGuide
# directly against the database (not the cached snapshot) so uncommitted
# writes can be validated by TopicChange::Checked.
module Topics::References
  module_function

  def broken
    datasets = TopicDataset.datasets.index_by(&:id)
    topics = {}
    found = {}
    TopicPage.includes(:holders, :questions, :sources, :routes).
      order(:position, :slug).each do |page|
        topics[page.slug] = topic = Topics::Topic.new(page.slug, page.data)
        found.merge!(in_topic(topic, datasets))
      rescue ArgumentError => e
        found[[:topic, page.slug]] = e.message
      end
    found.merge(in_guides(topics, datasets))
  end

  def in_topic(topic, datasets)
    Topics::Topic::NATIONS.keys.each_with_object({}) do |nation, found|
      names = holder_names(topic, nation)
      topic.questions.select { |question| question.for?(nation) }.
        each do |question|
          place = "“#{question.text}” (#{topic.title}, " \
                  "#{_(Topics::Topic::NATIONS[nation])})"
          dataset = in_nation(question.dataset, nation)
          if dataset && !datasets[dataset]&.for?(nation)
            found[[:dataset, topic.slug, question.slug, nation, dataset]] =
              "#{place} needs the dataset #{dataset}, covering " \
              "#{_(Topics::Topic::NATIONS[nation])}"
          end
          holder = in_nation(question.holder, nation)
          next unless question.ask && holder && !names.include?(holder)

          found[[:holder, topic.slug, question.slug, nation, holder]] =
            "#{place} needs the holder “#{holder}”"
        end
    end
  end

  def holder_names(topic, nation)
    holders = topic.holders.select { |holder| holder.for?(nation) }
    holders.flat_map { |each| [each.key, each.who] }
  end

  def in_guides(topics, datasets)
    TopicGuide.order(:id).each_with_object({}) do |guide, found|
      if guide.dataset_id && !datasets.key?(guide.dataset_id)
        found[[:guide, guide.id, :dataset]] =
          "a topic guide needs the dataset #{guide.dataset_id}"
      end
      next unless guide.topic_slug

      wordings = wordings_for(topics, guide)
      if wordings.empty?
        found[[:guide, guide.id, :question]] =
          "a topic guide needs the question #{guide.question_slug} in " \
          "#{guide.topic_slug}"
      elsif guide.dataset_id &&
            wordings.none? { |question| uses?(question, guide.dataset_id) }
        found[[:guide, guide.id, :pairing]] =
          "a topic guide is for “#{wordings.first.text}” from the dataset " \
          "#{guide.dataset_id}, which the question needs to use"
      end
    end
  end

  def wordings_for(topics, guide)
    topics[guide.topic_slug]&.questions.to_a.
      select { |question| question.slug == guide.question_slug }
  end

  def in_nation(value, nation)
    value.is_a?(Hash) ? value[nation] : value
  end

  def uses?(question, key)
    dataset = question.dataset
    (dataset.is_a?(Hash) ? dataset.values : Array(dataset)).include?(key)
  end
end
