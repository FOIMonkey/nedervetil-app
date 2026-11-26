# Helpers for rendering admin to-do list labels
module Admin::ToDoListHelper
  PRIORITY_IMPORTANT = %w[
    attention-messages
    requires-admin
  ].freeze

  PRIORITY_WARNING = %w[
    error-messages
    holding-pen
  ].freeze

  PRIORITY_INFO = %w[
    new-authorities
    update-authorities
  ].freeze

  PRIORITY_NONE = %w[
    blank-contacts
    unclassified
  ].freeze

  def todo_list_label_style(id)
    case id
    when *PRIORITY_NONE
      ''
    when *PRIORITY_INFO
      'label-info'
    when *PRIORITY_WARNING
      'label-warning'
    else
      # PRIORITY_IMPORTANT and any unknown id default to important
      'label-important'
    end
  end
end
