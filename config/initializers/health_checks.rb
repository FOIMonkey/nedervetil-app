require 'redis_connection'

Rails.application.config.after_initialize do
  user_last_created = HealthChecks::Checks::PeriodCheck.new(
    failure_message: _('The last user was created over a day ago'),
    success_message: _('The last user was created in the last day')
  ) do
    User.last.created_at
  end

  incoming_message_last_created = HealthChecks::Checks::PeriodCheck.new(
    failure_message: _('The last incoming message was created over a day ago'),
    success_message: _('The last incoming message was created in the last day')
  ) do
    IncomingMessage.last.created_at
  end

  outgoing_message_last_created = HealthChecks::Checks::PeriodCheck.new(
    failure_message: _('The last outgoing message was created over a day ago'),
    success_message: _('The last outgoing message was created in the last day')
  ) do
    OutgoingMessage.last.created_at
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

  HealthChecks.add user_last_created
  HealthChecks.add incoming_message_last_created
  HealthChecks.add outgoing_message_last_created
  HealthChecks.add person_check_configured
end
