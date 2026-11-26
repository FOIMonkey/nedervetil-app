# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Serves the main admin dashboard of pending tasks, the combined event and
# authority-change timeline, and summary site statistics.
class Admin::GeneralController < AdminController
  # A flat JSON body keeps the key it had before this controller moved here.
  wrap_parameters :admin_general, exclude: []

  include AdminGeneralTimelineHelper

  QUEUE_FILTERS = %w[all documents holding_pen reported authorities].freeze
  REPORTED_STATES = %w[
    requires_admin
    error_message
    attention_requested
  ].freeze
  QUEUE_LIMIT = 50

  def index
    @queue_filter = if QUEUE_FILTERS.include?(params[:queue])
                      params[:queue]
                    else
                      'all'
                    end

    load_request_queues
    load_authority_queues
    load_document_queue

    @announcements = Announcement.
      for_user_with_roles(current_user, :admin).
      limit(3)

    @initial_triage = select_initial_triage
  end

  def timeline
    # Recent events
    @events_title = events_title

    @events = WillPaginate::Collection.create(
      (params[:page] or 1), 100
    ) do |pager|
      # get the relevant slice from the paginator
      events, count = get_timeline_events(pager)

      # inject the result array into the paginated collection:
      pager.replace(events)

      # set the total entries for the page to the overall number of results
      pager.total_entries = count
    end
  end

  def stats
    # Overview counts of things
    @public_body_count = PublicBody.count

    @info_request_count = InfoRequest.count
    @outgoing_message_count = OutgoingMessage.count
    @incoming_message_count = IncomingMessage.count

    @user_count = User.count

    @request_by_state =
      InfoRequest.group('described_state').order('described_state').count
  end

  private

  def load_request_queues
    reset_request_queues
    load_holding_pen if %w[all holding_pen].include?(@queue_filter)
    load_reported_requests if %w[all reported].include?(@queue_filter)

    @public_request_tasks = @holding_pen_count.positive? ||
                            @reported_count.positive?
  end

  def reset_request_queues
    @holding_pen_count = 0
    @holding_pen_messages = []
    @requires_admin_count = 0
    @error_message_count = 0
    @attention_count = 0
    @reported_count = 0
    @error_message_requests = []
    @attention_requests = []
    @requires_admin_requests = []
    @latest_events = {}
  end

  def load_holding_pen
    pen = InfoRequest.holding_pen_request
    return unless pen

    @holding_pen_count = pen.incoming_messages.count
    @holding_pen_messages = pen.incoming_messages.
                            includes(:raw_email).
                            reorder(created_at: :desc, id: :desc).
                            limit(QUEUE_LIMIT).
                            to_a.reverse
  end

  def load_reported_requests
    state_counts = InfoRequest.where(described_state: REPORTED_STATES).
                   group(:described_state).count
    @requires_admin_count = state_counts['requires_admin'].to_i
    @error_message_count = state_counts['error_message'].to_i
    @attention_count = state_counts['attention_requested'].to_i
    @reported_count = @requires_admin_count + @error_message_count +
                      @attention_count

    if @error_message_count.positive?
      @error_message_requests = bounded_requests_in_state('error_message')
    end
    if @attention_count.positive?
      @attention_requests = bounded_requests_in_state('attention_requested')
    end
    if @requires_admin_count.positive?
      @requires_admin_requests = bounded_requests_in_state('requires_admin')
    end
    @latest_events = batch_latest_events(
      @error_message_requests + @attention_requests + @requires_admin_requests
    )
  end

  def load_authority_queues
    reset_authority_queues
    fetch_authority_queues if %w[all authorities].include?(@queue_filter)

    @authority_tasks = @blank_contact_count.positive? ||
                       @new_body_count.positive? ||
                       @body_update_count.positive?
    @authority_queue_count = @blank_contact_count + @new_body_count +
                             @body_update_count + @map_count
  end

  def reset_authority_queues
    @blank_contact_count = 0
    @new_body_count = 0
    @body_update_count = 0
    @blank_contacts = []
    @new_body_requests = []
    @body_update_requests = []
    @map_count = 0
  end

  def fetch_authority_queues
    @blank_contact_count = PublicBody.without_request_email.count
    cr_counts = PublicBodyChangeRequest.open.
                group(Arel.sql('public_body_id IS NULL')).count
    @new_body_count = cr_counts[true].to_i
    @body_update_count = cr_counts[false].to_i
    load_authority_queue_records
    @map = AuthorityGroups::Map.check
    @map_count = @map.not_on_map.size + @map.old_codes.size + @map.shared.size
  end

  def load_authority_queue_records
    if @blank_contact_count.positive?
      @blank_contacts = PublicBody.without_request_email.
                        includes(:translations).limit(20).to_a
    end
    if @new_body_count.positive?
      @new_body_requests = PublicBodyChangeRequest.
                           includes(:user).
                           new_body_requests.open.
                           limit(QUEUE_LIMIT).to_a
    end
    return unless @body_update_count.positive?

    @body_update_requests = PublicBodyChangeRequest.
                            includes(:user, public_body: :translations).
                            body_update_requests.open.
                            limit(QUEUE_LIMIT).to_a
  end

  def load_document_queue
    if %w[all documents].include?(@queue_filter)
      @review_queue = Disclosures::ReviewQueue.new(current_ability)
      @documents_count = @review_queue.count
    else
      @review_queue = nil
      @documents_count = 0
    end
  end

  def bounded_requests_in_state(state)
    InfoRequest.where(described_state: state).
      order(updated_at: :desc).
      limit(QUEUE_LIMIT).
      to_a
  end

  def batch_latest_events(requests)
    ids = requests.map(&:id)
    return {} if ids.empty?

    InfoRequestEvent.
      select('DISTINCT ON (info_request_id) info_request_events.*').
      where(info_request_id: ids).
      order(:info_request_id, id: :desc).
      index_by(&:info_request_id)
  end

  def select_initial_triage
    initial_triage_candidates.first
  end

  def initial_triage_candidates
    initial_document_candidates +
      initial_holding_pen_candidates +
      initial_reported_candidates +
      initial_authority_candidates
  end

  def initial_document_candidates
    return [] unless %w[all documents].include?(@queue_filter) && @review_queue

    doc = @review_queue.drafts.first&.document ||
          @review_queue.source_changed.first
    att = @review_queue.attachment_drafts.first
    list = []
    list << { kind: 'document', record: doc } if doc
    list << { kind: 'attachment', record: att } if att
    list
  end

  def initial_holding_pen_candidates
    return [] unless %w[all holding_pen].include?(@queue_filter)

    msg = @holding_pen_messages.first
    msg ? [{ kind: 'holding_pen', record: msg }] : []
  end

  def initial_reported_candidates
    return [] unless %w[all reported].include?(@queue_filter)

    req = @error_message_requests.first || @attention_requests.first ||
          @requires_admin_requests.first
    req ? [{ kind: 'request', record: req }] : []
  end

  def initial_authority_candidates
    return [] unless %w[all authorities].include?(@queue_filter)

    cr = @new_body_requests.first || @body_update_requests.first
    body = @blank_contacts.first
    list = []
    list << { kind: 'change_request', record: cr } if cr
    list << { kind: 'blank_contact', record: body } if body
    list
  end

  def events_title
    if current_time_filter == 'All time'
      "#{current_event_type}, all time"
    else
      "#{current_event_type} in the last #{current_time_filter.downcase}"
    end
  end

  def get_timeline_events(pager)
    authority_scope = timeline_scope(
      PublicBody::Version, 'PublicBody::Version', :updated_at, pager
    )
    event_scope = timeline_scope(
      InfoRequestEvent, 'InfoRequestEvent', :created_at, pager
    )
    rows, count = timeline_rows_and_count(authority_scope, event_scope, pager)
    [hydrate_timeline_records(rows), count]
  end

  def timeline_scope(model, type_label, column, pager)
    model.
      select("id, '#{type_label}' as type, #{column} AS timestamp").
      where(column => start_date...).
      order(timestamp: :desc).
      limit(pager.per_page).
      offset(pager.offset)
  end

  def timeline_count(scope)
    scope.unscope(:select, :order, :limit, :offset).count
  end

  def timeline_scope_rows(scope)
    scope.map do |row|
      { 'id' => row.id, 'type' => row.type, 'timestamp' => row.timestamp }
    end
  end

  def timeline_rows_and_count(authority_scope, event_scope, pager)
    case params[:event_type]
    when 'authority_change'
      [timeline_scope_rows(authority_scope), timeline_count(authority_scope)]
    when 'info_request_event'
      [timeline_scope_rows(event_scope), timeline_count(event_scope)]
    else
      count = timeline_count(authority_scope) + timeline_count(event_scope)
      [timeline_union_rows(authority_scope, event_scope, pager), count]
    end
  end

  def timeline_union_rows(authority_scope, event_scope, pager)
    query = ActiveRecord::Base.sanitize_sql_array(
      [<<~SQL.squish, limit: pager.per_page, offset: pager.offset]
        (#{authority_scope.unscope(:order, :limit, :offset).to_sql})
        UNION ALL
        (#{event_scope.unscope(:order, :limit, :offset).to_sql})
        ORDER BY timestamp DESC
        LIMIT :limit OFFSET :offset
      SQL
    )
    ActiveRecord::Base.connection.select_all(query).to_a
  end

  def hydrate_timeline_records(rows)
    event_ids = timeline_ids_for(rows, 'InfoRequestEvent')
    version_ids = timeline_ids_for(rows, 'PublicBody::Version')
    events_by_id = load_timeline_map(
      InfoRequestEvent, :info_request, event_ids
    )
    versions_by_id = load_timeline_map(
      PublicBody::Version, :public_body, version_ids
    )

    rows.filter_map do |row|
      map = row['type'] == 'InfoRequestEvent' ? events_by_id : versions_by_id
      record = map[row['id'].to_i]
      [record, row['timestamp']] if record
    end
  end

  def timeline_ids_for(rows, type)
    rows.select { |row| row['type'] == type }.map { |row| row['id'].to_i }
  end

  def load_timeline_map(model, association, ids)
    return {} if ids.empty?

    model.includes(association).where(id: ids).index_by(&:id)
  end
end
