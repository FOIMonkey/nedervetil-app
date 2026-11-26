module Topics
  # View helpers for topic pages; unknown authorities or tags fall back to
  # OtherSite search (wdtk:) or plain text.
  module TopicsHelper
    def topic_link_to(text, to)
      url = topic_url(to) or return text
      unless url.start_with?('http')
        return link_to(text, request_journey_link_path(url))
      end

      link_to(url, class: 'topic-out') do
        safe_join([text, tag.span(" #{_('(another site)')}",
                                  class: 'visually-hidden')])
      end
    end

    def topic_url(to)
      return unless to

      (to['body'] && (body = topic_body(to['body'])) &&
       public_body_path(body)) ||
        (to['tag'] && topic_tag_path(to['tag'])) ||
        to['url'] ||
        ((query = to['wdtk'] || to['body']) && OtherSite.url(query))
    end

    def topic_ask_path(to, topic: nil, question: nil, nation: nil)
      return unless to

      body = to['body'] && topic_body(to['body'])
      return unless body || (to['tag'] && topic_tag_path(to['tag']))

      # A different question starts a separate request: the menu resumes the
      # saved draft, whose wording must not be paired with this title.
      choices = question ? {} : request_journey_choices
      context = choices.fetch(:journey, {}).
                merge('topic' => topic&.slug,
                      'nation' => nation,
                      'holder' => to['tag']).compact
      choices[:public_body] = body&.url_name
      choices[:journey] = context.presence
      if question
        choices[:subject] = RequestLetter.subject(question.text)
        choices[:question] = question.text
      end
      new_alaveteli_pro_info_request_path(choices.compact)
    end

    GEOGRAPHY = { 'ward' => N_('by ward'),
                  'lsoa' => N_('by neighbourhood'),
                  'msoa' => N_('by neighbourhood'),
                  'la' => N_('by council'),
                  'force' => N_('by police force'),
                  'fire' => N_('by fire service'),
                  'trust' => N_('by NHS trust'),
                  'icb' => N_('by health board'),
                  'court' => N_('by court'),
                  'prison' => N_('by prison'),
                  'centre' => N_('by test centre'),
                  'site' => N_('by site'),
                  'grid' => N_('by 1 km square'),
                  'line' => N_('by operator'),
                  'region' => N_('by region') }.freeze

    def topic_dataset_note(dataset)
      [dataset.title,
       (geography = GEOGRAPHY[dataset.geography]) && _(geography),
       dataset.frequency].compact.join(' · ')
    end

    def topic_other_site?(rows)
      rows.any? { |row| topic_other_site_url?(row.to) }
    end

    def topic_other_site_url?(to)
      OtherSite.link?(topic_url(to))
    end

    def topic_ask_elsewhere(topic, ask, nation)
      return ask['wdtk'] if ask['wdtk']
      return ask['body'] if ask['body']

      topic.holders.find do |holder|
        holder.for?(nation) && holder.to &&
          holder.to['tag'] == ask['tag'] && holder.to['wdtk']
      end&.to&.fetch('wdtk')
    end

    # England is the default, so it stays out of the address.
    def topic_place(nation)
      nation unless nation == 'england'
    end

    def topic_page_path(topic, nation, **params)
      request_journey_link_path(
        topic_path(topic.slug, nation: topic_place(nation), **params)
      )
    end

    def topic_question_page_path(topic, question, nation)
      request_journey_link_path(
        topic_question_path(topic.slug, question.slug,
                            nation: topic_place(nation))
      )
    end

    def topic_holders_page_path(topic, nation)
      request_journey_link_path(
        topic_holders_path(topic.slug, nation: topic_place(nation))
      )
    end

    def topic_front_path(step, nation)
      request_journey_link_path(
        topics_path(step: step.presence, nation: topic_place(nation))
      )
    end

    def topic_row(label, path, note: nil, quiet: false)
      link_to path, class: ['triage-reply', ('triage-reply--quiet' if quiet)] do
        safe_join([tag.span(label, class: 'triage-reply__label'),
                   (tag.span(note, class: 'triage-reply__topic') if note)])
      end
    end

    def topic_who(entry)
      ask = entry.question.ask
      entry.holder&.who || ask['body'] ||
        (_('Your council') if ask['tag'].to_s.end_with?('council'))
    end

    # Restricts nation-specific tags when filtering a multi-nation holder.
    NATION_GROUPS = { 'scottish_council' => 'scotland',
                      'welsh_council' => 'wales',
                      'ni_council' => 'northern_ireland',
                      'hsc_trust' => 'northern_ireland' }.freeze

    # Council holders link to place lookup rather than individual council types.
    def topic_council?(holder)
      holder.to.present? && holder.to['tag'].to_s.end_with?('council')
    end

    def topic_groups(groups, nation = nil)
      (groups || []).filter_map do |group|
        next if nation && NATION_GROUPS.fetch(group['tag'], nation) != nation

        (path = topic_tag_path(group['tag'])) &&
          [group['label'], request_journey_link_path(path)]
      end
    end

    # Geometry (rem) for --beam-N tangent clip-paths on the topics home page;
    # must stay in sync with .torch in the theme's _topics.scss.
    TORCH = { badger: 15.0,
              row: 4.75,
              rows_start: 25.0,
              cx: 0.485,
              cy: 0.4675,
              r: 0.285 }.freeze

    def torch_style(rows)
      size, height, start = TORCH.values_at(:badger, :row, :rows_start)
      cx = size * TORCH[:cx]
      cy = (((rows * height) - size) / 2) + (size * TORCH[:cy])
      r = size * TORCH[:r]
      beams = (0...rows).map do |row|
        top = row * height
        bottom = top + height
        upper = torch_tangent(cx, cy, r, start, top).min_by(&:last)
        lower = torch_tangent(cx, cy, r, start, bottom).max_by(&:last)
        points = [upper, [start, top]].map { |x, y| "#{rem(x)} #{rem(y)}" } +
                 ["100% #{rem(top)}", "100% #{rem(bottom)}"] +
                 [[start, bottom], lower].map { |x, y| "#{rem(x)} #{rem(y)}" }
        "--beam-#{row}: polygon(#{points.join(', ')})"
      end
      (["--rows: #{rows}"] + beams).join('; ')
    end

    def torch_tangent(cx, cy, r, px, py)
      angle = Math.atan2(py - cy, px - cx)
      spread = Math.acos(r / Math.hypot(px - cx, py - cy))
      [angle - spread, angle + spread].map do |a|
        [cx + (r * Math.cos(a)), cy + (r * Math.sin(a))]
      end
    end

    def topic_documents(topic, limit, nation = 'england')
      documents = Disclosures::Document.listed.
        where(public_id: topic.documents).
        preload({ public_body: :translations },
                { thumbnail_attachment: :blob },
                foi_attachment: :file_blob).
        index_by(&:public_id).values_at(*topic.documents).compact
      authorities = documents.filter_map do |document|
        document.public_view.authority
      end.uniq
      ActiveRecord::Associations::Preloader.new(records: authorities,
                                                associations: :tags).call
      documents.select do |document|
        authority = document.public_view.authority
        (authority ? Holds.nation(authority) : 'england') == nation
      end.first(limit)
    end

    # England omits group: because /documents cannot exclude other nations.
    def topic_documents_filter(topic, nation)
      { topic: topic.slug, group: (nation unless nation == 'england') }.compact
    end

    private

    def rem(value)
      "#{value.round(3)}rem"
    end

    def topic_body(name)
      @topic_bodies ||= {}
      @topic_bodies.fetch(name) do
        @topic_bodies[name] = PublicBody.find_by_name(name)
      end
    end

    def topic_tag_path(tag)
      @topic_tag_paths ||= {}
      @topic_tag_paths.fetch(tag) do
        @topic_tag_paths[tag] =
          if AuthorityGroups::Group.find(tag)
            authority_group_path(tag)
          elsif PublicBody.with_tag(tag).exists?
            list_public_bodies_by_tag_path(tag)
          end
      end
    end
  end
end
