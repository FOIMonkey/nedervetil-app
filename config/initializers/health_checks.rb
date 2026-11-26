require 'redis_connection'

Rails.application.config.after_initialize do
  user_last_created = HealthChecks::Checks::PeriodCheck.new(
    failure_message: _('The last user was created over a day ago'),
    success_message: _('The last user was created in the last day')
  ) do
    User.order(id: :desc).pick(:created_at)
  end

  incoming_message_last_created = HealthChecks::Checks::PeriodCheck.new(
    failure_message: _('The last incoming message was created over a day ago'),
    success_message: _('The last incoming message was created in the last day')
  ) do
    IncomingMessage.order(id: :desc).pick(:created_at)
  end

  outgoing_message_last_created = HealthChecks::Checks::PeriodCheck.new(
    failure_message: _('The last outgoing message was created over a day ago'),
    success_message: _('The last outgoing message was created in the last day')
  ) do
    OutgoingMessage.order(id: :desc).pick(:created_at)
  end

  # The person check fails closed outside development and test, so without
  # its keys every form it protects refuses (Turnstile).
  person_check_configured = HealthChecks::Checks::ConditionCheck.new(
    failure_message: _('The person check (Turnstile) has no keys, so the ' \
                       'forms it protects refuse everyone'),
    success_message: _('The person check (Turnstile) has its keys')
  ) do
    Rails.env.local? || Turnstile.configured?
  end

  pdf_masking = HealthChecks::Checks::PDFMaskingCheck.new(
    failure_message: _('PDF masking can’t run'),
    success_message: _('PDF masking can run')
  )

  outlook_conversion = HealthChecks::Checks::OutlookConversionCheck.new(
    failure_message: _('Attached Outlook messages can’t be converted'),
    success_message: _('Attached Outlook messages can be converted')
  )

  mail_read = HealthChecks::Checks::MailReadCheck.new(
    failure_message: _('Incoming mail can’t be read'),
    success_message: _('Incoming mail can be read')
  )

  office_worker = HealthChecks::Checks::OfficeWorkerCheck.new(
    failure_message: _('The Office worker can’t run'),
    success_message: _('The Office worker can run')
  )

  HealthChecks.add user_last_created
  HealthChecks.add incoming_message_last_created
  HealthChecks.add outgoing_message_last_created
  HealthChecks.add pdf_masking
  HealthChecks.add outlook_conversion
  HealthChecks.add mail_read
  HealthChecks.add office_worker
  HealthChecks.add person_check_configured
end
