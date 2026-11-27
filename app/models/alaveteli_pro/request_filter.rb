require 'will_paginate/array'

module AlaveteliPro
  # Form-backed query object for filtering, searching and ordering a user's
  # inbox RequestSummaries by text, phase, IncomingAttention state and deadline.
  class RequestFilter
    extend ActiveModel::Naming
    include ActiveModel::Conversion

    attr_accessor :filter, :order, :search

    def update(attributes = {})
      self.attributes = attributes
    end

    def attributes=(attributes)
      self.filter = attributes[:filter] unless attributes[:filter].blank?
      self.order = attributes[:order]
      self.search = attributes[:search]
    end

    def order_options
      order_attributes.map { |atts| [atts[:capital_label], atts[:param]] }
    end

    def order_label
      return _('next deadline') if order == 'next_deadline'

      if order_params.include?(@order)
        order_labels[@order]
      else
        order_labels[default_order]
      end
    end

    def filter_label
      if filter_params.include?(@filter)
        filter_labels[@filter]
      else
        filter_labels[nil]
      end
    end

    def filter_capital_label
      if filter_params.include?(@filter)
        filter_capital_labels[@filter]
      else
        filter_capital_labels[nil]
      end
    end

    def results(user)
      request_summaries =
        IncomingAttention::Effective.visible_summaries(user.request_summaries,
                                                       user)
      escaped = ActiveRecord::Base.sanitize_sql_like(search.to_s)
      request_summaries =
        request_summaries.
          includes(:request_summary_categories).
            where("title ILIKE :q
                   OR body ILIKE :q
                   OR public_body_names ILIKE :q",
                   q: "%#{escaped}%").
              references(:request_summary_categories)
      request_summaries = filter_results(request_summaries, user)
      request_summaries = request_summaries.
        merge(RequestSummary.order(order_value))
      return request_summaries unless order == 'next_deadline'

      # Sorted in Ruby because deadline order depends on events, not one column.
      Deadlines::Overview.sort_summaries(request_summaries, user)
    end

    def filter_results(results, user = nil)
      if IncomingAttention::Effective.active?
        attention = attention_results(results, user)
        return attention if attention
      end

      if filter_value.blank?
        results.not_category('draft')
      else
        results.category(filter_value)
      end
    end

    def persisted?
      false
    end

    def default_order
      'updated_at_desc'
    end

    private

    def order_attributes
      [
        { param: 'updated_at_desc',
          value: 'request_updated_at DESC',
          label: _('last updated'),
          capital_label: _('Last updated') },
        { param: 'created_at_asc',
          value: 'request_created_at ASC',
          label: _('first created'),
          capital_label: _('First created') },
        { param: 'title_asc',
          value: 'title ASC',
          label: _('title (A-Z)'),
          capital_label: _('Title (A-Z)') },
        { param: 'next_deadline',
          value: 'request_updated_at DESC',
          label: _('next deadline'),
          capital_label: _('Next deadline') }
      ]
    end

    def order_params
      order_attributes.map { |atts| atts[:param] }
    end

    def order_values
      Hash[order_attributes.map { |atts| [atts[:param], atts[:value]] }]
    end

    def order_labels
      Hash[order_attributes.map { |atts| [atts[:param], atts[:label]] }]
    end

    def order_value
      if order_params.include?(@order)
        order_values[@order]
      else
        order_values[default_order]
      end
    end

    def default_filters
      [
        { param: nil,
          value: nil,
          label: _('all requests'),
          capital_label: _('All requests') },
        { param: 'draft',
          value: :draft,
          label: _('drafts'),
          capital_label: _('Drafts') }
      ]
    end

    def phase_filters
      InfoRequest::State.phases.map { |phase|
  { param: phase[:scope].to_s,
    value: phase[:scope],
    label: phase[:label],
    capital_label: phase[:capital_label] }
}
    end

    def filter_attributes
      attributes = default_filters + phase_filters
      return attributes unless IncomingAttention::Effective.active?

      attributes + attention_filters
    end

    def attention_filters
      [
        { param: 'needs_attention',
          value: :needs_attention,
          label: _('needs attention'),
          capital_label: _('Needs attention') },
        { param: 'routine_updates',
          value: :routine_updates,
          label: _('routine updates'),
          capital_label: _('Routine updates') }
      ]
    end

    # Effective phase depends on AI reply predictions, not stored categories.
    def attention_results(results, user)
      effective = IncomingAttention::Effective
      case filter
      when 'needs_attention'
        effective.summaries(results, :needs_attention, user: user)
      when 'routine_updates'
        effective.summaries(results, :routine, user: user)
      when *InfoRequest::State.phases.map { |phase| phase[:scope].to_s }
        effective.phase_summaries(results, filter, user: user)
      end
    end

    def filter_options
      filter_attributes.map { |atts| [atts[:capital_label], atts[:param]] }
    end

    def filter_capital_labels
      Hash[filter_options].invert
    end

    def filter_params
      filter_attributes.map { |atts| atts[:param] }
    end

    def filter_values
      Hash[filter_attributes.map { |atts| [atts[:param], atts[:value]] }]
    end

    def filter_labels
      Hash[filter_attributes.map { |atts| [atts[:param], atts[:label]] }]
    end

    def filter_value
      if filter_params.include?(@filter)
        filter_values[@filter]
      else
        filter_values[nil]
      end
    end
  end
end
