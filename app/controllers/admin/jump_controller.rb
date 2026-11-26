# Global admin jump/search endpoint and reusable record picker results for
# requests, users, authorities, documents and admin tools. Uses PostgreSQL
# full-text search indexes and exact indexed lookups instead of leading-% LIKE.
class Admin::JumpController < AdminController
  MAX_PER_GROUP = 6

  def show
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['Vary'] = 'Turbo-Frame'

    @query = params[:q].to_s.strip.first(120)
    @scope = if %w[all users bodies requests].include?(params[:scope])
               params[:scope]
             else
               'all'
             end
    @frame_id = safe_frame_id(params[:frame])
    @exclude_id = params[:exclude_id].to_i

    @bodies = search_bodies if %w[all bodies].include?(@scope)
    @requests = search_requests if %w[all requests].include?(@scope)
    @users = search_users if %w[all users].include?(@scope)
    @documents = search_documents if @scope == 'all'
    @tools = filter_tools if @scope == 'all'

    return unless turbo_frame_request? || params[:frame].present?

    if %w[users bodies requests].include?(@scope)
      render partial: 'admin/jump/picker_results', layout: false
    else
      render partial: 'admin/jump/results', layout: false
    end
  end

  private

  def safe_frame_id(raw)
    return 'admin_jump_results' unless /\A[a-z0-9_-]{1,64}\z/i.match?(raw.to_s)

    raw.to_s
  end

  def search_requests
    return [] if @scope == 'all' && @query.blank?
    return recent_requests if @query.blank?

    clean = @query.delete_prefix('#')
    results = [exact_request_match(clean)].compact
    results.concat(fts_request_matches(clean)) if clean.length >= 2
    results.concat(body_request_matches) if include_body_requests?(results)

    results.uniq(&:id).reject { |req| req.id == @exclude_id }.
      first(MAX_PER_GROUP)
  end

  def exact_request_match(clean)
    return unless /\A\d+\z/.match?(clean)

    exact = InfoRequest.includes(:user, public_body: :translations).
            find_by(id: clean.to_i)
    exact if exact && can?(:admin, exact)
  end

  def fts_request_matches(clean)
    InfoRequest.includes(:user, public_body: :translations).
      search_scope(clean, admin_mode: true, limit: MAX_PER_GROUP).
      to_a.select { |req| can?(:admin, req) }
  end

  def include_body_requests?(results)
    @scope == 'all' && @bodies.present? && results.size < MAX_PER_GROUP
  end

  def body_request_matches
    InfoRequest.includes(:user, public_body: :translations).
      where(public_body_id: @bodies.map(&:id)).
      order(updated_at: :desc).
      limit(MAX_PER_GROUP).
      to_a.select { |req| can?(:admin, req) }
  end

  def recent_requests
    InfoRequest.includes(:user, public_body: :translations).
      order(updated_at: :desc).
      limit(MAX_PER_GROUP).
      to_a.select { |req| can?(:admin, req) }.
      reject { |req| req.id == @exclude_id }
  end

  def search_users
    return [] if @scope == 'all' && @query.blank?

    scope = User.all
    scope = scope.where.not(id: @exclude_id) if @exclude_id.positive?
    return scope.order(:id).limit(MAX_PER_GROUP).to_a if @query.blank?

    clean = @query.delete_prefix('@').strip
    results = []

    exact = scope.find_by_url_name(clean) || scope.find_user_by_email(clean)
    results << exact if exact

    if clean.length >= 2
      fts = scope.search_scope(clean, admin_mode: true, limit: MAX_PER_GROUP).
            to_a
      results.concat(fts)
    end

    results.uniq(&:id).first(MAX_PER_GROUP)
  end

  def search_bodies
    return [] if @scope == 'all' && @query.blank?

    scope = PublicBody.includes(:translations)
    scope = scope.where.not(id: @exclude_id) if @exclude_id.positive?
    return scope.order(:id).limit(MAX_PER_GROUP).to_a if @query.blank?

    results = []
    exact = scope.find_by_url_name(@query)
    results << exact if exact

    if @query.length >= 2
      fts = scope.search_scope(@query, admin_mode: true, limit: MAX_PER_GROUP).
            to_a
      results.concat(fts)
    end

    results.uniq(&:id).first(MAX_PER_GROUP)
  end

  def search_documents
    return [] if @query.blank?

    results = []
    if Disclosures::Document::PUBLIC_ID.match?(@query)
      exact = Disclosures::Document.includes(public_body: :translations).
              find_by(public_id: @query)
      results << exact if exact && can?(:manage_document, exact)
    end

    if @query.length >= 2
      fts = Disclosures::Document.
            includes(public_body: :translations).
            where(
              "disclosure_documents.search_vector @@ " \
              "websearch_to_tsquery('english', ?)",
              @query
            ).
            order(updated_at: :desc).
            limit(MAX_PER_GROUP).
            to_a.select { |doc| can?(:manage_document, doc) }
      results.concat(fts)
    end

    results.uniq(&:id).first(MAX_PER_GROUP)
  end

  def filter_tools
    all_tools = helpers.admin_tool_groups.flat_map do |group, links|
      links.map { |label, path| { group: group, label: label, path: path } }
    end
    return all_tools.first(8) if @query.blank?

    term = @query.downcase
    all_tools.select do |tool|
      tool[:label].downcase.include?(term) ||
        tool[:group].downcase.include?(term)
    end.first(8)
  end
end
