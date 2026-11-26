# Keeps a TopicChange for each create, update and destroy, in the same
# transaction, with Current.user as who made it. Only callbacks see a write,
# so these models never use update_all, delete_all or dependent: :delete_all.
module TopicChange::Recorded
  extend ActiveSupport::Concern
  include TopicChange::Checked

  UNRECORDED = %w[id created_at updated_at].freeze

  included do
    after_create { record_change('create', saved_changes) }
    after_update { record_change('update', saved_changes) }
    after_destroy do
      record_change('destroy', attributes.
        reject { |name, value| value == self.class.column_defaults[name] }.
        transform_values { |value| [value, nil] })
    end
  end

  private

  def record_change(action, changes)
    changes = changes.except(*UNRECORDED)
    return if changes.empty?

    TopicChange.create!(user: Current.user, record: self, action: action,
                        changeset: changes)
  end
end
