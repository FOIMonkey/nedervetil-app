module AuthorityFeeds
  # Records an authority is expected to hold from Topics, minus per-authority
  # exclusions stored as `holds_not:<key>` tags.
  class Holdings
    TAG = 'holds_not'.freeze
    # First words that stay capitalised in "Usually, for a Scottish council".
    PROPER = %w[Scottish Welsh English London Northern NHS].freeze

    def initialize(body)
      @body = body
    end

    def all
      @all ||= defined?(Topics::Holds) ? Topics::Holds.held(@body).uniq { |holder, _| holder.what } : []
    end

    def unticked
      @body.tags.
        select { |tag| tag.name == TAG && tag.value.present? }.
        map(&:value)
    end

    def items
      off = unticked
      all.reject { |holder, _| holder.key && off.include?(holder.key) }
    end

    def type_group
      return @type_group if defined?(@type_group)

      @type_group = @body.tags.map(&:name).lazy.
                    filter_map { |tag| AuthorityGroups::Group.find(tag) }.
                    find { |group| group.heading_key == 'type' }
    end

    def kind
      @kind ||= type_group&.title&.singularize || (defined?(Topics::Holds) ? Topics::Holds.kind(@body) : nil)
    end

    def kind_phrase
      kind = self.kind or return nil
      nation = defined?(Topics::Topic) ? _(Topics::Topic::NATIONS.fetch(Topics::Holds.nation(@body))) : _('England')
      text = if PROPER.include?(kind.split.first)
               kind
             else
               kind.sub(/\A\p{Lu}(?=\p{Ll})/, &:downcase)
             end
      phrase = if text.match?(/\A[aeiou]/i)
                 _('an {{kind}}', kind: text)
               else
                 _('a {{kind}}', kind: text)
               end
      if kind.match?(/Scottish|Welsh|Northern Ireland|English|London/)
        phrase
      else
        _('{{kind}} in {{nation}}', kind: phrase, nation: nation)
      end
    end

    def self.untick!(body, keys, editor:)
      kept = body.tag_string.to_s.split.
             reject { |tag| tag.start_with?("#{TAG}:") }
      body.tag_string =
        (kept + keys.uniq.sort.map { |key| "#{TAG}:#{key}" }).join(' ')
      body.last_edit_editor = editor
      body.last_edit_comment = 'What they hold'
      body.save!
    end
  end
end
