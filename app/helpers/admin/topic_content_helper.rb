# Form fields, labels, and human-readable history formatting for the admin's
# topic content pages. The fields post what Admin::TopicContentEditing reads.
module Admin::TopicContentHelper
  TOPIC_RECORDS = {
    'TopicPage' => %w[Topic title],
    'TopicHolder' => %w[Holder who],
    'TopicQuestion' => %w[Question text],
    'TopicSource' => ['Published source', 'label'],
    'TopicRoute' => ['Other route', 'what'],
    'TopicDataset' => %w[Dataset title]
  }.freeze

  ROW_ASSOCIATIONS = {
    'TopicHolder' => 'holders',
    'TopicQuestion' => 'questions',
    'TopicSource' => 'sources',
    'TopicRoute' => 'routes'
  }.freeze

  LINK_INPUTS = {
    'body' => 'Authority name', 'tag' => 'Authority tag',
    'url' => 'Web address', 'wdtk' => 'Other-site search'
  }.freeze

  HIDDEN_DIFF_FIELDS = %w[topic_page_id].freeze

  DIFF_FIELD_LABELS = {
    'text' => 'Question',
    'to' => 'Link',
    'ask' => 'Ask link',
    'elsewhere_heading' => 'Other routes heading',
    'table_title' => 'Table',
    'url' => 'Web address',
    'area_url' => 'Area address',
    'area_codes' => 'Area codes',
    'published_label' => 'Published label',
    'warning_title' => 'Warning title',
    'warning_text' => 'Warning text'
  }.freeze

  def topic_record_kind(type)
    TOPIC_RECORDS.fetch(type.to_s).first
  end

  def topic_record_label(record)
    record.public_send(TOPIC_RECORDS.fetch(record.class.name).last)
  end

  def topic_row_association(record)
    ROW_ASSOCIATIONS[record.class.name]
  end

  def topic_link_preview(value)
    format_topic_link(value)
  end

  def topic_change_by(change)
    if change.user
      link_to(change.user.name, admin_user_path(change.user))
    elsif change.imported?
      'Import'
    else
      'Command line'
    end
  end

  def topic_change_label(change)
    return topic_record_label(change.record) if change.record

    field = TOPIC_RECORDS.fetch(change.record_type).last
    Array(change.changeset[field]).compact.first || "##{change.record_id}"
  end

  def topic_change_path(change)
    case (record = change.record)
    when nil then nil
    when TopicPage::Row then [:edit, :admin, record.topic_page, record]
    else [:edit, :admin, record]
    end
  end

  def topic_change_value(value, field: nil)
    return tag.em('empty', class: 'muted') if topic_value_blank?(value)

    text = format_topic_diff_value(field, value)
    tag.span(truncate(text, length: 180), title: text)
  end

  def topic_change_entries(change)
    entries = []
    change.changeset.each do |field, (before, after)|
      next if HIDDEN_DIFF_FIELDS.include?(field)

      if nation_map_update?(change, field, before, after)
        entries.concat(nation_map_diff_entries(field, before, after))
        next
      end
      next if skip_snapshot_field?(change, before, after)

      entries << [topic_diff_label(field), field, before, after]
    end
    entries
  end

  def topic_change_summary(change, entries)
    count = pluralize(entries.size, 'field')
    highlights = entries.filter_map do |_label, field, before, after|
      val = change.action == 'destroy' ? before : after
      next if topic_value_blank?(val)

      case field
      when 'nations' then topic_nations_text(val)
      when 'to', 'ask' then format_topic_link(val)
      when 'slug', 'key' then val
      when 'what', 'who', 'title', 'publisher'
        truncate(val.to_s, length: 48)
      end
    end.uniq.first(2)

    prefix = change.action == 'destroy' ? "Removed (#{count})" : "#{count} set"
    highlights.any? ? "#{prefix} · #{highlights.join(' · ')}" : prefix
  end

  def topic_errors(record)
    return if record.errors.empty?

    tag.div(class: 'alert alert-error', role: 'alert') do
      tag.ul { safe_join(record.errors.full_messages.map { tag.li(_1) }) }
    end
  end

  def topic_nations_text(nations)
    return 'All' if nations.blank?

    nations.map { |key| Topics::Topic::NATIONS.fetch(key, key) }.join(', ')
  end

  def topic_control(f, attribute, label, help = nil, compact: false, &block)
    error = f.object.errors[attribute].any?
    classes = ['admin-field', ('admin-field--compact' if compact),
               ('error' if error)].compact
    tag.div(class: classes) do
      label_tag("#{f.object_name}_#{attribute}", label,
                class: 'admin-field__label') +
        tag.div(class: 'admin-field__input') do
          capture(&block) + (help ? tag.span(help, class: 'help-block') : '')
        end
    end
  end

  def topic_text_field(f, attribute, label, help = nil, area: false, rows: 3, **options)
    topic_control(f, attribute, label, help) do
      if area
        f.text_area(attribute, rows: rows, **options)
      else
        f.text_field(attribute, **options)
      end
    end
  end

  def topic_lines_field(f, attribute, label, help = 'One per line.', rows: 3)
    topic_control(f, attribute, label, help) do
      text_area_tag("#{f.object_name}[#{attribute}]",
                    Array(f.object.public_send(attribute)).join("\n"),
                    rows: rows,
                    id: "#{f.object_name}_#{attribute}")
    end
  end

  def topic_nations_field(f, help = 'Tick none for all nations.')
    name = "#{f.object_name}[nations][]"
    topic_control(f, :nations, 'Nations', help) do
      hidden_field_tag(name, '', id: nil) +
        tag.div(class: 'admin-nations-row') do
          safe_join(Topics::Topic::NATIONS.map do |key, nation|
            tag.label(class: 'checkbox-inline') do
              check_box_tag(name, key, f.object.nations.include?(key),
                            id: "#{f.object_name}_nations_#{key}") +
                tag.span(nation)
            end
          end)
        end
    end
  end

  def topic_link_field(f, attribute, label)
    link = f.object.public_send(attribute) || {}
    error = f.object.errors[attribute].any?
    tag.fieldset(class: ['admin-subfields', ('error' if error)].compact) do
      tag.legend(label, class: 'admin-subfields__legend') +
        tag.div(class: 'admin-subfields__grid') do
          safe_join(LINK_INPUTS.map do |key, input|
            field_id = "#{f.object_name}_#{attribute}_#{key}"
            tag.div(class: 'admin-subfields__item') do
              label_tag(field_id, input, class: 'admin-subfields__label') +
                text_field_tag("#{f.object_name}[#{attribute}][#{key}]",
                               link[key],
                               id: field_id,
                               placeholder: input,
                               'aria-label': "#{label}: #{input}")
            end
          end)
        end +
        tag.span('Fill one, or an authority tag with an other-site search.',
                 class: 'help-block')
    end
  end

  def topic_nation_inputs(f, attribute, label, help = nil)
    values = f.object.public_send(attribute)
    error = f.object.errors[attribute].any?
    tag.fieldset(class: ['admin-subfields', ('error' if error)].compact) do
      tag.legend(label, class: 'admin-subfields__legend') +
        tag.div(class: 'admin-subfields__grid') do
          safe_join(Topics::Topic::NATIONS.map do |key, nation|
            field_id = "#{f.object_name}_#{attribute}_#{key}"
            tag.div(class: 'admin-subfields__item') do
              label_tag(field_id, nation, class: 'admin-subfields__label') +
                text_field_tag("#{f.object_name}[#{attribute}][#{key}]",
                               values[key],
                               id: field_id,
                               placeholder: nation,
                               'aria-label': "#{label}: #{nation}")
            end
          end)
        end +
        (help ? tag.span(help, class: 'help-block') : '')
    end
  end

  def topic_groups_field(f)
    rows = f.object.groups + [{}, {}]
    error = f.object.errors[:groups].any?
    tag.fieldset(class: ['admin-subfields', ('error' if error)].compact) do
      tag.legend('Groups', class: 'admin-subfields__legend') +
        tag.div(class: 'admin-groups-grid') do
          header = tag.div(class: 'admin-groups-grid__head muted') do
            tag.span('Group label') + tag.span('Authority tag')
          end
          body = safe_join(rows.each_with_index.map do |group, index|
            name = "#{f.object_name}[groups][#{index}]"
            tag.div(class: 'admin-groups-grid__row') do
              topic_group_inputs(name, group)
            end
          end)
          header + body
        end +
        tag.span('Kinds of authority here that hold them, by label and tag.',
                 class: 'help-block')
    end
  end

  # Preserves an unmatched selected key so saving does not silently drop it.
  def topic_dataset_options(selected)
    @topic_dataset_groups ||=
      TopicDataset.order(:publisher, :title).group_by(&:publisher).
      map do |publisher, datasets|
        [publisher, datasets.map { ["#{_1.title} (#{_1.key})", _1.key] }]
      end
    grouped_options_for_select(
      missing_option(@topic_dataset_groups, selected), selected
    )
  end

  def topic_holder_options(topic_page, selected)
    groups = topic_page.holders.group_by { topic_nations_text(_1.nations) }.
             map do |nations, holders|
      [nations, holders.map { [holder_option_label(_1), holder_value(_1)] }]
    end
    grouped_options_for_select(missing_option(groups, selected), selected)
  end

  private

  def topic_diff_label(field)
    DIFF_FIELD_LABELS.fetch(field.to_s) { field.to_s.humanize }
  end

  def topic_value_blank?(value)
    value.nil? || value == '' || value == [] || value == {}
  end

  def nation_map_update?(change, field, before, after)
    change.action == 'update' &&
      %w[dataset holder titles].include?(field) &&
      (before.is_a?(Hash) || after.is_a?(Hash))
  end

  def nation_map_diff_entries(field, before, after)
    before_map = before.is_a?(Hash) ? before : {}
    after_map = after.is_a?(Hash) ? after : {}
    Topics::Topic::NATIONS.filter_map do |key, nation|
      next if before_map[key] == after_map[key]

      [
        "#{topic_diff_label(field)} (#{nation})",
        field,
        before_map[key],
        after_map[key]
      ]
    end
  end

  def skip_snapshot_field?(change, before, after)
    (change.action == 'create' && topic_value_blank?(after)) ||
      (change.action == 'destroy' && topic_value_blank?(before))
  end

  def format_topic_diff_value(field, value)
    case field.to_s
    when 'nations'
      value.is_a?(Array) ? topic_nations_text(value) : value.to_s
    when 'to', 'ask'
      format_topic_link(value)
    when 'groups'
      format_topic_groups(value)
    when 'dataset', 'holder', 'titles'
      format_topic_nation_map(value)
    when 'partial'
      value ? 'Yes' : 'No'
    else
      format_generic_diff_value(value)
    end
  end

  def format_generic_diff_value(value)
    case value
    when Array then value.join(', ')
    when Hash then value.map { |k, v| "#{k}: #{v}" }.join('; ')
    else value.to_s
    end
  end

  def format_topic_link(value)
    return value.to_s unless value.is_a?(Hash)

    labels = { 'tag' => 'Tag', 'body' => 'Authority',
               'url' => 'URL', 'wdtk' => 'Search' }
    value.filter_map do |k, v|
      "#{labels.fetch(k.to_s, k.to_s.humanize)}: #{v}" if v.present?
    end.join(' · ')
  end

  def format_topic_groups(value)
    return value.to_s unless value.is_a?(Array)

    value.filter_map do |item|
      if item.is_a?(Hash)
        lbl = item['label'].presence
        tg = item['tag'].presence
        if lbl && tg
          "#{lbl} (#{tg})"
        else
          lbl || tg
        end
      else
        item.to_s
      end
    end.join(', ')
  end

  def format_topic_nation_map(value)
    return value.to_s unless value.is_a?(Hash)

    value.filter_map do |key, val|
      next if val.blank?

      nation = Topics::Topic::NATIONS.fetch(key.to_s, key.to_s.humanize)
      "#{nation}: #{val}"
    end.join(' · ')
  end

  def topic_group_inputs(name, group)
    label = text_field_tag("#{name}[label]", group['label'],
                           id: nil, placeholder: 'e.g. County councils',
                           'aria-label': 'Group label')
    tag_input = text_field_tag("#{name}[tag]", group['tag'],
                               id: nil, placeholder: 'e.g. county_council',
                               'aria-label': 'Group tag')
    safe_join([label, tag_input])
  end

  def holder_option_label(holder)
    "#{holder.who} (#{holder.what})"
  end

  def holder_value(holder)
    holder.key.presence || holder.who
  end

  def missing_option(groups, selected)
    listed = groups.any? { |_, options| options.any? { _2 == selected } }
    return groups if selected.blank? || listed

    groups + [['Not found', [[selected, selected]]]]
  end
end
