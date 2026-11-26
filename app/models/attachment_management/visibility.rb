module AttachmentManagement
  # Says who can see an attachment, in words for the Manage screen. Requests
  # are private, so it is the requester and admins unless an admin hid it
  # from the requester, or it is a spreadsheet still being checked
  # (Ability::RequesterVisible).
  module Visibility
    def self.describe(attachment)
      if Ability::RequesterVisible.requester?(attachment)
        return _('The requester and admins only. Not published.')
      end
      unless Ability::RequesterVisible.hidden_by_admin?(attachment)
        return _('Admins only, until it’s been checked.')
      end

      _('Admins only (hidden).')
    end
  end
end
