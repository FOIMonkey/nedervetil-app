# Renders status and role badge spans for a User row in the admin users list.
module AdminUsersHelper
  def user_labels(user)
    labels = []
    labels << banned_label if user.banned?
    labels << closed_label if user.closed?
    labels.concat(user.roles.map { |role| role_label(role) })
    safe_join(labels)
  end

  private

  def banned_label
    content_tag(:span, 'banned', class: 'label label-warning')
  end

  def closed_label
    content_tag(:span, 'closed', class: 'label label-warning')
  end

  def role_label(role)
    content_tag(:span, role.name, class: 'label')
  end
end
