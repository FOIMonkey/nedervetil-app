# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Sends user-account emails for sign-in confirmation, duplicate registration
# notices and email-address change confirmation and warnings.
class UserMailer < ApplicationMailer
  def confirm_login(user, reasons, url)
    @reasons = reasons
    @name = user.name
    @url = url

    subject = reasons[:email_subject] || _(
      'Confirm your account on {{site_name}}', site_name: site_name
    )
    mail_user(user, subject: -> { subject })
  end

  def already_registered(user, reasons, url)
    @reasons = reasons
    @name = user.name
    @url = url

    subject = reasons[:email_subject] || _(
      'Your account on {{site_name}}', site_name: site_name
    )
    mail_user(user, subject: -> { subject })
  end

  def changeemail_confirm(user, new_email, url)
    @name = user.name
    @url = url
    @old_email = user.email
    @new_email = new_email

    # Sent to new_email so clicking proves ownership before switching sign-in
    # and recovery; using the current user's locale is fine.
    subject = _(
      "Confirm your new email address on {{site_name}}",
      site_name: site_name
    )
    mail_user(new_email, subject: -> { subject })
  end

  # Notifies the current address so the owner sees unauthorised change attempts.
  def changeemail_requested(user, new_email)
    @name = user.name
    @new_email = new_email

    subject = _(
      "Someone asked to change your email address on {{site_name}}",
      site_name: site_name
    )
    mail_user(user, subject: -> { subject })
  end

  def changeemail_already_used(old_email, new_email)
    @old_email = old_email
    @new_email = new_email

    # Cannot send the user to mail_user - that would send to old_email.
    # No problem if the current locale is the user's.
    subject = _(
      "Unable to change email address on {{site_name}}",
      site_name: site_name
    )
    mail_user(new_email, subject: -> { subject })
  end
end
