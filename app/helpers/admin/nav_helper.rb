# Helpers for the Option C admin navigation bar, contextual domain sub-navs,
# and Jump/Tools directory.
module Admin::NavHelper
  REQUEST_MODEL_TYPES = %w[
    InfoRequest IncomingMessage OutgoingMessage OutgoingMessage::Snippet
  ].freeze
  SUBNAV_EXACT_ONLY = %w[
    /admin/users /admin/bodies /admin/requests /documents
  ].freeze

  def nav_li(path)
    tag.li class: nav_li_class(path) do
      yield
    end
  end

  def admin_page?
    controller.is_a?(AdminController)
  end

  def admin_domain_current(domain)
    'page' if admin_domain_active?(domain)
  end

  def admin_tool_groups
    requests_links = []
    if feature_enabled?(:admin_outgoing_messages)
      requests_links << ['Outgoing messages', admin_outgoing_messages_path]
    end
    if feature_enabled?(:admin_mail_server_logs)
      requests_links << ['Mail server logs', admin_mail_server_logs_path]
    end
    requests_links += [
      ['Request events', admin_info_request_events_path],
      ['Request categories',
       admin_categories_path(model_type: 'InfoRequest')],
      ['Request tags', admin_tags_path(model_type: 'InfoRequest')]
    ]
    if feature_enabled?(:refusal_snippets)
      requests_links << ['Snippets', admin_snippets_path]
    end

    authorities_links = [
      ['Authority pages', admin_authority_pages_path],
      ['Groups', admin_authority_groups_path],
      ['External releases', admin_external_releases_path],
      ['Authority categories',
       admin_categories_path(model_type: 'PublicBody')],
      ['Authority tags', admin_tags_path(model_type: 'PublicBody')]
    ]
    if feature_enabled?(:admin_public_body_change_requests)
      authorities_links << ['Change requests', admin_change_requests_path]
    end

    {
      'Summary' => [
        ['Jump search', admin_jump_path],
        ['Timeline', admin_timeline_path],
        ['Stats', admin_stats_path],
        ['Debug', admin_debug_index_path]
      ],
      'Requests' => requests_links,
      'Authorities' => authorities_links,
      'Users' => [
        ['Sign-ins', admin_sign_ins_path],
        ['User tags', admin_tags_path(model_type: 'User')],
        ['Two factor', admin_two_factor_path]
      ],
      'Topics & documents' => [
        ['Document review', disclosure_document_reviews_path],
        ['Published documents', disclosure_documents_path],
        ['Topics', admin_topic_pages_path],
        ['Datasets', admin_topic_datasets_path],
        ['Topic guides', admin_topic_guides_path],
        ['Topic history', admin_topic_changes_path]
      ],
      'System' => [
        ['Announcements', admin_announcements_path],
        ['Censor rules', admin_censor_rules_path],
        ['Holidays', admin_holidays_path],
        ['Notes', admin_notes_path],
        ['Spam addresses', admin_spam_addresses_path]
      ]
    }
  end

  def admin_subnav_section
    path = request.path
    return nil if path == '/admin' || path.start_with?('/admin/triage')

    if request_domain_path?(path)
      { domain: 'Requests', items: request_subnav_items }
    elsif document_domain_path?(path)
      { domain: 'Documents', items: document_subnav_items }
    elsif authority_domain_path?(path)
      { domain: 'Authorities', items: authority_subnav_items }
    elsif user_domain_path?(path)
      { domain: 'Users', items: user_subnav_items }
    elsif topic_domain_path?(path)
      { domain: 'Topics', items: topic_subnav_items }
    elsif system_domain_path?(path)
      { domain: 'System', items: system_subnav_items }
    end
  end

  def admin_subnav_current(path)
    return 'page' if current_page?(path)

    base = path.split('?').first
    return nil if base.blank? || SUBNAV_EXACT_ONLY.include?(base)
    return nil unless subnav_prefix_matches?(base)
    return 'page' if path.exclude?('?') || subnav_query_matches?(path)

    nil
  end

  private

  def admin_domain_active?(domain)
    case domain
    when :today
      request.path == '/admin' || request.path.start_with?('/admin/triage')
    when :documents then document_domain_path?(request.path)
    when :requests then request_domain_path?(request.path)
    when :authorities then authority_domain_path?(request.path)
    when :users then user_domain_path?(request.path)
    when :topics then topic_domain_path?(request.path)
    when :system then system_domain_path?(request.path)
    else false
    end
  end

  def subnav_prefix_matches?(base)
    request.path.start_with?("#{base}/") ||
      (base == '/admin/holidays' &&
        request.path.start_with?('/admin/holiday_imports'))
  end

  def subnav_query_matches?(path)
    query = Rack::Utils.parse_nested_query(path.split('?', 2).last)
    query.all? do |key, value|
      params[key].to_s == value.to_s ||
        (key == 'model_type' && value == 'PublicBody' &&
          params[:model_type].blank?)
    end
  end

  def nav_li_class(path)
    'active' if current_page?(path)
  end

  def request_domain_path?(path)
    path.start_with?('/admin/requests', '/admin/info_request_events',
                     '/admin/incoming_messages', '/admin/outgoing_messages',
                     '/admin/mail_server_logs', '/admin/snippets',
                     '/admin/raw_emails', '/admin/attachments',
                     '/admin/batches') ||
      (path.start_with?('/admin/categories', '/admin/tags') &&
        REQUEST_MODEL_TYPES.include?(params[:model_type]))
  end

  def document_domain_path?(path)
    path.start_with?('/documents/review', '/admin/documents')
  end

  def authority_domain_path?(path)
    path.start_with?('/admin/bodies', '/admin/authority_groups',
                     '/admin/external_release', '/admin/authority_pages',
                     '/admin/authority_feeds', '/admin/authority_links',
                     '/admin/change_requests') ||
      (path.start_with?('/admin/categories', '/admin/tags') &&
        (params[:model_type].blank? || params[:model_type] == 'PublicBody'))
  end

  def user_domain_path?(path)
    path.start_with?('/admin/users', '/admin/sign_ins', '/admin/two_factor') ||
      (path.start_with?('/admin/tags') && params[:model_type] == 'User')
  end

  def topic_domain_path?(path)
    path.start_with?('/admin/topics', '/admin/datasets', '/admin/topic_guides',
                     '/admin/topic_history')
  end

  def system_domain_path?(path)
    path.start_with?('/admin/censor_rules', '/admin/spam_addresses',
                     '/admin/announcements', '/admin/notes', '/admin/holidays',
                     '/admin/holiday_imports', '/admin/timeline',
                     '/admin/stats', '/admin/debug', '/admin/changelog')
  end

  def request_subnav_items
    items = [['All requests', admin_requests_path]]
    items << ['Events', admin_info_request_events_path]
    if feature_enabled?(:admin_outgoing_messages)
      items << ['Outgoing messages', admin_outgoing_messages_path]
    end
    if feature_enabled?(:admin_mail_server_logs)
      items << ['Mail server logs', admin_mail_server_logs_path]
    end
    items << ['Categories', admin_categories_path(model_type: 'InfoRequest')]
    items << ['Tags', admin_tags_path(model_type: 'InfoRequest')]
    if feature_enabled?(:refusal_snippets)
      items << ['Snippets', admin_snippets_path]
    end
    items
  end

  def document_subnav_items
    [
      ['Review queue', disclosure_document_reviews_path],
      ['Published documents', disclosure_documents_path]
    ]
  end

  def authority_subnav_items
    items = [['All authorities', admin_bodies_path]]
    if feature_enabled?(:admin_public_body_change_requests)
      items << ['Change requests', admin_change_requests_path]
    end
    items + [
      ['Groups', admin_authority_groups_path],
      ['Authority pages', admin_authority_pages_path],
      ['External releases', admin_external_releases_path],
      ['Categories', admin_categories_path(model_type: 'PublicBody')],
      ['Tags', admin_tags_path(model_type: 'PublicBody')]
    ]
  end

  def user_subnav_items
    [
      ['All', admin_users_path],
      ['Active', active_admin_users_path],
      ['Banned', banned_admin_users_path],
      ['Closed', closed_admin_users_path],
      ['Sign-ins', admin_sign_ins_path],
      ['Two factor', admin_two_factor_path],
      ['Tags', admin_tags_path(model_type: 'User')]
    ]
  end

  def topic_subnav_items
    [
      ['Topics', admin_topic_pages_path],
      ['Datasets', admin_topic_datasets_path],
      ['Topic guides', admin_topic_guides_path],
      ['Topic history', admin_topic_changes_path]
    ]
  end

  def system_subnav_items
    [
      ['Censor rules', admin_censor_rules_path],
      ['Spam addresses', admin_spam_addresses_path],
      ['Announcements', admin_announcements_path],
      ['Notes', admin_notes_path],
      ['Holidays', admin_holidays_path],
      ['Timeline', admin_timeline_path],
      ['Stats', admin_stats_path],
      ['Debug', admin_debug_index_path],
      ['Changelog', admin_changelog_index_path]
    ]
  end
end
