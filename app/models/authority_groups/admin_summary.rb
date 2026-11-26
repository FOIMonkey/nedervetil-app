module AuthorityGroups
  # Lazy-loaded summary data for an authority's admin page.
  class AdminSummary
    RECENT = 5

    attr_reader :body

    def initialize(body)
      @body = body
    end

    # The stored address, even when a setting sends every request elsewhere.
    def foi_address
      body.read_attribute(:request_email)
    end

    def groups
      @groups ||= Group.headings.filter_map do |key, heading|
        tagged = tagged_groups(heading)
        [key, tagged] unless tagged.empty?
      end.to_h
    end

    def area_codes
      body.tags.select { |tag| tag.name == 'gss' && tag.value.present? }.
        map(&:value)
    end

    def other_tags
      group_tags = groups.values.flatten.map(&:category_tag)
      body.tags.reject do |tag|
        tag.name == 'gss' || group_tags.include?(tag.name)
      end
    end

    def holdings
      @holdings ||= held.all.select { |holder, _topic| holder.key }.
                    uniq { |holder, _topic| holder.key }
    end

    def ticked?(holder)
      !unticked.include?(holder.key)
    end

    def named_holders
      @named_holders ||= (defined?(Topics::Topic) ? Topics::Topic.all : []).flat_map(&:holders).
                         select { |holder| holder.to&.dig('body') == body.name }
    end

    def who_line
      WhoLine.find_by(public_body: body)&.line
    end

    def default_who_line
      defined?(Topics::Holds) ? Topics::Holds.brief(named_holders.map(&:what)) : nil
    end

    def request_count
      @request_count ||= body.info_requests.count
    end

    def document_count
      @document_count ||= documents.count
    end

    def recent_documents
      documents.limit(RECENT)
    end

    def more_documents?
      document_count > RECENT
    end

    def release_count
      @release_count ||= releases.count
    end

    def recent_releases
      releases.newest_first.limit(RECENT)
    end

    private

    def tagged_groups(heading)
      names = body.tags.map(&:name)
      Category.with_parent(heading).includes(:translations).
        select { |category| names.include?(category.category_tag) }
    end

    def held
      @held ||= AuthorityFeeds::Holdings.new(body)
    end

    def unticked
      @unticked ||= held.unticked
    end

    def documents
      Disclosures::Document.listed.where(public_body_id: body.id).
        order('disclosure_documents.published_at DESC, ' \
              'disclosure_documents.id DESC')
    end

    def releases
      ExternalRelease.where(public_body_id: body.id)
    end
  end
end
