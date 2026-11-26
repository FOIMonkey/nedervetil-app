# Base Action Mailbox router; routes all inbound email to RequestMailbox.
class ApplicationMailbox < ActionMailbox::Base
  routing all: :request
end
