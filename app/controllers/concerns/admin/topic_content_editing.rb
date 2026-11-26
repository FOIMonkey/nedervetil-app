# Shared param permitting/parsing and Current.user attribution for admin
# topic-content forms.
module Admin::TopicContentEditing
  extend ActiveSupport::Concern

  SAVED = 'Saved. It’s live on the site.'.freeze
  DELETED = 'Deleted. It’s gone from the site.'.freeze
  LINK_KEYS = %w[body tag url wdtk].freeze

  included do
    before_action { Current.user = current_user }
  end

  private

  # Only include submitted keys so omitted fields keep their existing values.
  def content_params(key, fields)
    form = params.require(key).
      permit(*fields.map { |name, kind| permit(name, kind) })
    fields.each_with_object({}) do |(name, kind), values|
      values[name] = parse(kind, form[name]) if form.key?(name)
    end
  end

  def permit(name, kind)
    case kind
    when :nations then { name => [] }
    when :link then { name => LINK_KEYS }
    when :nation_map then { name => Topics::Topic::NATIONS.keys }
    when :groups then { name => %w[label tag] }
    else name
    end
  end

  def parse(kind, value)
    case kind
    when :text then value.to_s.strip.presence
    when :lines then value.to_s.lines.map(&:strip).compact_blank
    when :flag then value == '1' || nil
    when :nations then Array(value).compact_blank
    when :link then stripped(value).presence
    when :nation_map then stripped(value)
    when :groups then stripped_groups(value)
    end
  end

  def stripped_groups(value)
    value.to_hash.values.map { |group| stripped(group) }.reject(&:empty?)
  end

  def stripped(hash)
    hash.to_hash.transform_values { |each| each.to_s.strip }.compact_blank
  end
end
