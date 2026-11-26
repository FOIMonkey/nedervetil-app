module AuthorityGroups
  # Lists are relations, so callers paginate them in SQL; member counts for a
  # whole heading come from one grouped query.
  class Group
    PINNED_MAX = 10
    RESERVED_TAGS = %w[all other].freeze

    attr_reader :category, :heading_key

    class << self
      def headings
        root = Category.roots.includes(:translations).
               find { |category| category.title == 'PublicBody' }
        return {} unless root

        found = Category.with_parent(root).includes(:translations).
                index_by(&:title)
        HEADINGS.filter_map do |title, (key, _label)|
          [key, found[title]] if found[title]
        end.to_h
      end

      def label(key)
        label = HEADINGS.values.to_h[key]
        label && _(label)
      end

      def listing(heading)
        in_heading(heading).
          joins("INNER JOIN (#{member_counts(heading).to_sql}) member_counts " \
                'ON member_counts.name = categories.category_tag').
          where(authority_group_settings: { hidden_at: nil }).
          select('categories.*, member_counts.members AS members_count')
      end

      def admin_listing(heading)
        in_heading(heading).
          joins("LEFT JOIN (#{member_counts(heading).to_sql}) member_counts " \
                'ON member_counts.name = categories.category_tag').
          select('categories.*, ' \
                 'COALESCE(member_counts.members, 0) AS members_count, ' \
                 'authority_group_settings.hidden_at AS hidden_at')
      end

      def find(tag, include_hidden: false)
        return nil unless valid_tag?(tag)

        keys = headings.to_h { |key, heading| [heading.id, key] }
        category = Category.joins(:parent_relationships).
                   where(category_relationships: { parent_id: keys.keys },
                         category_tag: tag).
                   select('categories.*, ' \
                          'category_relationships.parent_id AS heading_id').
                   order('categories.id').first
        return nil unless category

        group = new(category, keys[category.heading_id])
        group if include_hidden || !group.hidden?
      end

      def valid_tag?(tag)
        tag.to_s.match?(TAG) && tag.to_s.length > 1 &&
          !RESERVED_TAGS.include?(tag.to_s)
      end

      private

      def in_heading(heading)
        Category.joins(:parent_relationships).
          where(category_relationships: { parent_id: heading.id }).
          where("categories.category_tag ~ '^[a-z0-9_]{2,}$'").
          where.not(category_tag: RESERVED_TAGS).
          joins('LEFT JOIN authority_group_settings ' \
                'ON authority_group_settings.category_id = categories.id').
          order('category_relationships.position, categories.id').
          includes(:translations)
      end

      def member_counts(heading)
        tags = Category.with_parent(heading).select(:category_tag)
        HasTagString::HasTagStringTag.
          where(model_type: 'PublicBody',
                name: tags,
                model_id: PublicBody.visible.select(:id)).
          group(:name).
          select('has_tag_string_tags.name, ' \
                 'COUNT(DISTINCT has_tag_string_tags.model_id) AS members')
      end
    end

    def initialize(category, heading_key)
      @category = category
      @heading_key = heading_key
    end

    def tag
      category.category_tag
    end

    def title
      category.title
    end

    def intro
      category.body
    end

    def heading_label
      self.class.label(heading_key)
    end

    def hidden?
      Setting.where(category_id: category.id).where.not(hidden_at: nil).exists?
    end

    def bodies
      PublicBody.visible.where(
        id: HasTagString::HasTagStringTag.
          where(model_type: 'PublicBody', name: tag).select(:model_id)
      )
    end

    def bodies_by_name
      bodies.with_translations(AlaveteliLocalization.locale).
        merge(PublicBody::Translation.order(:name))
    end

    # Groups members under their first type category in admin order, then nil.
    def bodies_by_kind
      types = if (heading = self.class.headings['type'])
                self.class.listing(heading).to_a
              else
                []
              end
      kinds = kinds_by_body(types)
      order = types.map(&:category_tag)
      grouped = bodies_by_name.to_a.group_by do |body|
        Array(kinds[body.id]).min_by { |tag| order.index(tag) }
      end
      grouped.
        sort_by { |tag, _| tag ? order.index(tag) : order.size }.
        map do |tag, members|
          [types.find { |type| type.category_tag == tag }, members]
        end
    end

    def documents
      Disclosures::Document.listed.
        where(public_body_id: bodies.select(:id)).
        order('disclosure_documents.published_at DESC, ' \
              'disclosure_documents.id DESC')
    end

    def public_documents
      documents.preload(public_body: :translations)
    end

    # Pluck ids so Postgres avoids scanning all releases for small groups.
    def body_ids
      @body_ids ||= bodies.pluck(:id)
    end

    def releases
      ExternalRelease.visible.where(public_body_id: body_ids)
    end

    def pinned_releases
      releases.pinned.order(pinned_at: :desc).limit(PINNED_MAX).
        includes(public_body: :translations)
    end

    def latest_releases
      releases.unpinned.newest_first.includes(public_body: :translations)
    end

    private

    def kinds_by_body(types)
      HasTagString::HasTagStringTag.
        where(model_type: 'PublicBody',
              model_id: body_ids,
              name: types.map(&:category_tag)).
        pluck(:model_id, :name).group_by(&:first).
        transform_values { |pairs| pairs.map(&:last) }
    end
  end
end
