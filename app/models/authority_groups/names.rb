module AuthorityGroups
  # Authorities whose names have every word of a search, each word the start
  # of a word in the name: "northmoor" finds Northmoor County Council,
  # "potholes" finds nothing.
  module Names
    LIST = 3
    GROUPS = 4
    Match = Struct.new(:total, :bodies, :groups, keyword_init: true)

    module_function

    def match(query)
      words = query.to_s.downcase.scan(/[[:alnum:]]+/).
              select { |word| word.length > 2 }.uniq
      return Match.new(total: 0, bodies: [], groups: []) if words.empty?

      scope = PublicBody.visible.joins(:translations).
              where(public_body_translations:
                      { locale: AlaveteliLocalization.default_locale })
      words.each do |word|
        scope = scope.where('public_body_translations.name ~* ?', "\\m#{word}")
      end
      ids = scope.distinct.pluck(:id)
      if ids.size <= LIST
        return Match.new(total: ids.size,
                         bodies: PublicBody.where(id: ids).
                           includes(:translations).sort_by(&:name),
                         groups: [])
      end

      Match.new(total: ids.size, bodies: [], groups: type_groups(ids))
    end

    def type_groups(ids)
      heading = Group.headings['type'] or return []
      categories = Category.with_parent(heading).includes(:translations).
                   index_by(&:category_tag)
      counts = HasTagString::HasTagStringTag.
               where(model_type: 'PublicBody', model_id: ids,
                     name: categories.keys).
               group(:name).distinct.count(:model_id)
      counts.sort_by { |tag, count| [-count, tag] }.first(GROUPS).
        filter_map { |tag, count| (group = Group.find(tag)) && [group, count] }
    end
  end
end
