# Devise's notification interface with the site's existing delivery headers,
# locale handling and mail guards.
class AuthenticationMailer < ApplicationMailer
  def self.origin
    protocol = Rails.application.config.force_ssl ? 'https' : 'http'
    Rails.application.config.action_mailer.default_url_options.
      slice(:host, :protocol, :port).
      reverse_merge(protocol: protocol)
  end

  def confirmation_instructions(record, token, _opts = {})
    @confirmation_url = confirm_url(
      email_token: token, draft_claim: record.draft_claim_for_confirmation,
      **self.class.origin
    )
    mail_user(record, subject: -> { _('Confirm your email address') })
  end

  def reset_password_instructions(record, token, _opts = {})
    @reset_url = edit_password_change_url(id: token, **self.class.origin)
    mail_user(record, subject: -> { _('Reset your password') })
  end
end
