# Shared nested-translation helpers for Globalize models, ordering translations
# by available locales, building missing locales and ignoring blank submissions.
module Translatable
  extend ActiveSupport::Concern

  included do
    accepts_nested_attributes_for :translations,
                                  reject_if: :empty_translation_in_params?
  end

  def find_translation_by_locale(locale)
    translations.find_by_locale(locale)
  end

  def translated_versions
    translations
  end

  def ordered_translations
    locales = AlaveteliLocalization.available_locales
    translations.
      select { |translation| locales.include?(translation.locale.to_s) }.
      sort_by { |translation| locales.index(translation.locale.to_s) }
  end

  def build_all_translations
    AlaveteliLocalization.available_locales.each do |locale|
      if translations.none? { |translation| translation.locale.to_s == locale }
        translations.build(locale: locale)
      end
    end
  end

  private

  def empty_translation_in_params?(attributes)
    attributes.select { |k, v| v.present? && k.to_s != 'locale' }.empty?
  end
end
