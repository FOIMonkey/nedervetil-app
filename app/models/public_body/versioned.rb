# Records a PublicBody::Version snapshot on every save that changes the body.
module PublicBody::Versioned
  extend ActiveSupport::Concern

  # Omitted from snapshots, though changes to them still bump the version.
  NON_VERSIONED_COLUMNS = %w[id version created_at updated_at first_letter].
                          freeze

  included do
    has_many :versions, class_name: 'PublicBody::Version',
                        inverse_of: :public_body,
                        dependent: :delete_all

    before_save :number_version
    after_save :record_version
  end

  class_methods do
    def versioned_column_names
      column_names - NON_VERSIONED_COLUMNS
    end
  end

  private

  def number_version
    @record_version = new_record? || changed?
    return unless @record_version

    self.version = (new_record? ? 0 : versions.maximum(:version).to_i) + 1
  end

  def record_version
    return unless @record_version

    @record_version = nil
    snapshot = PublicBody::Version.new(public_body_id: id, version: version)
    self.class.versioned_column_names.each do |name|
      snapshot[name] = public_send(name) if has_attribute?(name)
    end
    snapshot.save!
  end
end
