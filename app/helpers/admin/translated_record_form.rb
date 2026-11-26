# FormBuilder for records translated with Globalize
class Admin::TranslatedRecordForm < ActionView::Helpers::FormBuilder
  def translated_fields
    fields = @template.tag.div(
      id: 'div-locales', data: { controller: 'locale-tabs' }
    ) do
      @template.concat(locale_tabs)

      locales = @template.tag.div class: 'tab-content' do
        object.ordered_translations.each_with_index do |translation, index|
          locale = translation.locale

          content = tab_pane(locale, index.zero?) do
            if AlaveteliLocalization.default_locale?(locale)
              @template.fields_for(object) do |t|
                locale_fields(t, locale) { yield t }
              end
            else
              fields_for(:translations, translation, child_index: locale) do |t|
                locale_fields(t, locale) { yield t }
              end
            end
          end

          @template.concat(content)
        end
      end

      @template.concat(locales)
    end

    @template.concat(fields)
  end

  def error_messages
    @template.tag.div class: 'error-messages' do
      default_locale_error_messages
      translation_error_messages
    end
  end

  private

  def locale_tabs
    @template.tag.ul class: 'locales nav nav-tabs', role: 'tablist' do
      object.ordered_translations.each_with_index do |translation, index|
        li = @template.tag.li(class: (index.zero? ? 'active' : nil),
                              role: 'presentation') do
          href = "#div-locale-#{translation.locale}"

          panel_id = "div-locale-#{translation.locale}"
          link = @template.link_to(
            href,
            role: 'tab',
            'aria-controls': panel_id,
            'aria-selected': index.zero?.to_s,
            data: { locale_tabs_target: 'tab',
                    action: 'click->locale-tabs#select' }
          ) do
            @template.concat(locale_name(translation.locale))
          end

          @template.concat(link)
        end

        @template.concat(li)
      end
    end
  end

  def tab_pane(locale, active)
    @template.tag.div id: "div-locale-#{locale}",
                      class: (active ? 'tab-pane active' : 'tab-pane'),
                      role: 'tabpanel',
                      data: { locale_tabs_target: 'panel' } do
      yield
    end
  end

  def locale_fields(t, locale)
    @template.concat t.hidden_field :locale, value: locale
    yield
  end

  def default_locale_error_messages
    default_locale_errors = object.errors.reject do |error|
      error.attribute.starts_with?('translation')
    end

    @template.concat(errors_for(default_locale, default_locale_errors))
  end

  def translation_error_messages
    object.ordered_translations.each do |translation|
      @template.concat(errors_for(translation.locale, translation.errors))
    end
  end

  def errors_for(locale, errors)
    return if errors.empty?

    @template.tag.div do
      @template.concat(locale_name(locale))

      ul = @template.tag.ul do
        errors.each do |error|
          content = @template.tag.li do
            "#{ error.attribute } #{ error.message }"
          end

          @template.concat(content)
        end
      end

      @template.concat(ul)
    end
  end

  def locale_name(locale)
    LanguageNames.get_language_name(locale.to_s) || locale.to_s
  end

  def default_locale
    AlaveteliLocalization.default_locale
  end
end
