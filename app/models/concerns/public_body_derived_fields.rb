# Mixed into PublicBody and PublicBody::Translation to keep url_name and
# first_letter derived from name and short_name.
module PublicBodyDerivedFields
  extend ActiveSupport::Concern

  included do
    before_save :set_first_letter

    # When name or short name is changed, also change the url name
    def short_name=(value)
      write_attribute(:short_name, value)
      update_url_name
    end

    def name=(value)
      write_attribute(:name, value)
      update_url_name
    end
  end

  # Normalise short_name before checking presence because Globalize stashes
  # unsaved writes outside ActiveRecord's `normalizes`.
  def short_or_long_name
    tidied = PublicBody::Translation.normalize_value_for(:short_name,
                                                         short_name)
    tidied ? short_name : name.to_s
  end

  # Set the first letter, which is used for faster queries
  def set_first_letter
    return if name.blank?

    # we use a regex to ensure it works with utf-8/multi-byte
    new_first_letter = name.scan(/^./mu)[0]&.upcase
    self.first_letter = new_first_letter if new_first_letter != first_letter
  end

  # Appends _2, _3, ... if another body already uses the slug in any locale,
  # ignoring this body's own translations.
  def update_url_name
    return unless changed.include?('name') || changed.include?('short_name')

    url_name = MySociety::Format.simplify_url_part(short_or_long_name, 'body')
    taken = other_bodies_url_name_numbers(url_name)
    self.url_name = taken.empty? ? url_name : "#{url_name}_#{taken.max + 1}"
  end

  private

  # "x" counts as 1 and "x_3" as 3.
  def other_bodies_url_name_numbers(url_name)
    own_body_id = is_a?(PublicBody::Translation) ? public_body_id : id
    scope = PublicBody::Translation.all
    scope = scope.where.not(public_body_id: own_body_id) if own_body_id

    scope.where('url_name ~ ?', "^#{url_name}(_\\d+)?$").
      pluck(:url_name).
      map { |taken| (taken[/_(\d+)$/, 1] || 1).to_i }
  end
end
