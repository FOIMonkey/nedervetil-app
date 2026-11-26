# View helpers for displaying RawEmails in the admin interface
module AdminRawEmailsHelper
  # Public: Format a list of email addresses for display.
  # Wraps each address in a <code> tag and joins the list with a comma.
  #
  # Returns a String
  def address_list(addresses)
    addresses = Array(addresses).compact
    safe_join(addresses.map { |addr| content_tag :code, addr }, ', ')
  end
end
