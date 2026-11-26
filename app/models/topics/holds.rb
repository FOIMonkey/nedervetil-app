module Topics
  # Resolves what records an authority or group usually holds from Topics.
  module Holds
    module_function

    def nation(body)
      (Topic::NATIONS.keys - ['england']).find do |nation|
        nation_tags(nation).any? { |tag| body.has_tag?(tag) }
      end || 'england'
    end

    # A sic: tag makes a body Scottish here too, as it does for deadlines.
    def nation_tags(nation)
      if nation == 'scotland'
        [Deadlines.scotland_tag, Deadlines.sic_tag]
      else
        [nation]
      end
    end

    def holders(body)
      held(body).map(&:first)
    end

    def held(body)
      tags = body.tags.map(&:name)
      nation = nation(body)
      holders =
        Topic.holder_pairs.
        select do |holder, _|
          holder.for?(nation) &&
            ((holder.groups || []).
               any? { |group| tags.include?(group['tag']) } ||
             holder.to&.dig('body') == body.name)
        end
      named, kind =
        holders.partition { |holder, _| holder.to&.dig('body') == body.name }
      named + kind
    end

    def figures(body)
      nation = nation(body)
      held(body).map(&:last).uniq.flat_map(&:questions).
        filter_map { |question| question.dataset_for(nation) }.uniq.
        filter_map do |dataset|
          [dataset, dataset.url_for(body)] if dataset.area?(body)
        end
    end

    def kind(body)
      tags = body.tags.map(&:name)
      group = Topic.all.flat_map(&:holders).
              flat_map { |holder| holder.groups || [] }.
              find { |g| tags.include?(g['tag']) }
      group && group['label'].singularize
    end

    def summary(body, limit: 2)
      held(body).uniq { |_, topic| topic.slug }.
        map { |holder, _| phrase(holder.what) }.first(limit).join('; ').presence
    end

    # Lowercase initial word unless the phrase contains a proper noun.
    def phrase(what)
      if what.split(',').first.match?(/\s[A-Z][a-z]/) ||
         AuthorityFeeds::Holdings::PROPER.include?(what[/\A\S+/])
        return what
      end

      what.sub(/\A[A-Z](?=[a-z])/, &:downcase)
    end

    # Breadth-first across comma-separated duties so councils show their range.
    def brief(whats, limit: 6)
      lists = whats.map do |what|
        what.split(',').map(&:strip).reject(&:empty?)
      end.reject(&:empty?)
      parts = (lists.map(&:first) + lists.flat_map { |list| list.drop(1) }).
              uniq.first(limit)
      ([parts.first] + parts.drop(1).map { |part| phrase(part) }).join(', ')
    end

    # Returns [[label, body_or_tag, whats]] for a group in two queries, sorted
    # by duty count descending.
    def for_group(ids, nation)
      tags = group_tags(ids)
      holders = nation_holders(nation)
      group_rows(holders, tags, members_by_name(ids, holders)).
        map { |label, (target, whats)| [label, target, whats.uniq] }.
        sort_by { |label, _, whats| [-whats.size, label] }
    end

    def group_tags(ids)
      HasTagString::HasTagStringTag.
        where(model_type: 'PublicBody', model_id: ids).
        distinct.pluck(:name)
    end

    def nation_holders(nation)
      Topic.all.flat_map(&:holders).
        select { |holder| nation.nil? || holder.for?(nation) }
    end

    def members_by_name(ids, holders)
      named = holders.filter_map { |holder| holder.to&.dig('body') }.uniq
      PublicBody.where(id: ids).
        with_translations(AlaveteliLocalization.locale).
        where(public_body_translations: { name: named }).
        index_by(&:name)
    end

    def group_rows(holders, tags, bodies)
      holders.each_with_object({}) do |holder, found|
        kind = (holder.groups || []).
               find { |group| tags.include?(group['tag']) }
        target = kind ? kind['tag'] : bodies[holder.to&.dig('body')]
        next unless target

        (found[kind ? kind['label'] : target.name] ||= [target, []])[1] <<
          holder.what
      end
    end

    # Omit default nation for ungrouped English bodies (may be UK-wide).
    def line(body)
      kind = kind(body)
      if kind || nation(body) != 'england'
        place = _(Topic::NATIONS.fetch(nation(body)))
      end
      holds = summary(body)
      [kind,
       place,
       holds && PlainTextTranslation._(
         'usually holds {{things}}', things: holds
       )].
        compact.join(' · ').presence
    end
  end
end
