# == Schema Information
#
# Table name: public_body_versions
#
#  id                 :bigint           not null, primary key
#  public_body_id     :integer
#  version            :integer
#  name               :text
#  short_name         :text
#  request_email      :text
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  last_edit_editor   :string
#  last_edit_comment  :text
#  url_name           :text
#  home_page          :text
#  publication_scheme :text
#  charity_number     :text
#  disclosure_log     :text
#

# One entry in a PublicBody's edit history, recorded by PublicBody::Versioned
# after each save that changed the body.
class PublicBody::Version < ApplicationRecord
  self.table_name = 'public_body_versions'

  belongs_to :public_body, inverse_of: :versions

  before_save :copy_translated_attributes

  def self.latest
    order(version: :desc).first
  end

  def previous
    return if public_body_id.nil? || version.nil?

    self.class.where(public_body_id: public_body_id).
      where(version: ...version).
      order(version: :desc).
      first
  end

  def copy_translated_attributes
    public_body.attributes.each do |name, value|
      if public_body.translated?(name) &&
         !PublicBody::Versioned::NON_VERSIONED_COLUMNS.include?(name)
        send("#{name}=", value)
      end
    end
  end

  def compare(previous = nil)
    if previous.nil?
      changes = []
    else
      changes = self.class.content_columns.inject([]) { |memo, c|
        unless %w(version
                  last_edit_editor
                  last_edit_comment
                  created_at
                  updated_at).include?(c.name)
          from = previous.send(c.name)
          to = send(c.name)
          memo << { name: c.name.humanize,
                    from: from,
                    to: to } if from != to
        end
        memo
      }
    end
    if block_given?
      changes.each do |change|
        yield(change)
      end
    end
    changes
  end

  def editor
    User.find_by(url_name: last_edit_editor)
  end
end
