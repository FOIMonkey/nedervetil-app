# Tells the site's admins that a spreadsheet was held back from its requester.
class SpreadsheetHoldMailer < ApplicationMailer
  def report(attachment, metadata)
    @attachment = attachment
    @metadata = metadata
    @info_request = attachment.info_request
    set_auto_generated_headers
    mail(from: contact_from_name_and_email,
         to: contact_from_name_and_email,
         subject: _('Spreadsheet held for checking [{{reference}}]',
                    reference: attachment.id))
  end

  # Its analysis was asked for again and again and hasn't run.
  def not_read(attachment)
    @attachment = attachment
    @info_request = attachment.info_request
    set_auto_generated_headers
    mail(from: contact_from_name_and_email,
         to: contact_from_name_and_email,
         subject: _('Spreadsheet not checked yet [{{reference}}]',
                    reference: attachment.id))
  end
end
