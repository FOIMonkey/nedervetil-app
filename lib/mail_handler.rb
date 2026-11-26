# Entry point for reading incoming email. MailHandler::Parts splits a mail
# into its parts, unpacking TNEF files and converting Outlook messages inside
# AlaveteliSandbox; MailHandler::Headers reads its header lines.
module MailHandler
  require 'mail_handler/parts'
  require 'mail_handler/headers'
  include Headers

  def backend
    'Mail'
  end

  # Minimal built-in .msg fixture for outlook_self_test.
  OUTLOOK_SELF_TEST = File.expand_path('mail_handler/self_test.msg', __dir__)

  # Verifies msgconvert works in the active execution mode; raises ReadRefused
  # on failure. Used by health checks and sandbox:check.
  def outlook_self_test
    source = outlook_as_mime(File.binread(OUTLOOK_SELF_TEST))
    return if source && Mail.from_source(source).subject ==
                        'Converter self-test'

    raise ReadRefused, 'msgconvert did not convert the built-in message'
  end

  # Turn instance methods into class methods
  extend self
end
