# Restricts sort_order to declared attributes in either sort direction.
#   sortable :name, :email, default: :name_asc
module Admin::Sortable
  extend ActiveSupport::Concern

  DEFAULT_SORTABLE_ATTRS = [:created_at, :updated_at].freeze

  included do
    helper_method :sort_options, :sort_query, :sort_order
  end

  class_methods do
    def sortable(*attrs, default: nil, only: nil, except: nil,
                 relevance: nil)
      attrs = attrs.any? ? attrs : DEFAULT_SORTABLE_ATTRS

      before_action only: only, except: except do
        configure_sort_options(attrs, relevance: relevance)
        configure_sort_order(default: default.to_s)
      end
    end
  end

  def sort_options
    @sort_options
  end

  def sort_order
    @sort_order
  end

  def sort_query
    @sort_options[@sort_order]
  end

  # Break ties by id in the same direction for stable pagination.
  def sorted(relation)
    return relation unless sort_query

    relation.reorder(sort_query).order(id: tie_direction)
  end

  private

  def tie_direction
    sort_query.end_with?('DESC') ? :desc : :asc
  end

  def configure_sort_options(attrs, relevance: nil)
    options = attrs.each_with_object({}) do |attr, h|
      h["#{attr}_asc"]  = "#{attr} ASC"
      h["#{attr}_desc"] = "#{attr} DESC"
    end

    offer_relevance = relevance && send(relevance)
    options = { relevance: nil }.merge(options) if offer_relevance

    @sort_options = options.with_indifferent_access
  end

  def configure_sort_order(default: nil)
    sort_order = params[:sort_order] || default
    @sort_order =
      if sort_order.in?(@sort_options.keys)
        sort_order
      else
        @sort_options.keys.first
      end
  end
end
