require 'spec_helper'
require "external_command"

def mailin_test(email_filename)
  Dir.chdir Rails.root do
    mail = load_file_fixture(email_filename)
    ir = info_requests(:other_request)
    mail.gsub!('EMAIL_TO', ir.incoming_email)
    mail.gsub!('EMAIL_FROM', 'responder@localhost')
    xc = ExternalCommand.new("script/mailin", stdin_string: mail).run
    expect(xc.err).to eq("")
    return xc
  end
end

RSpec.describe "When importing mail into the application" do
  # script/mailin stores the mail from a process of its own, so no transaction
  # here can roll it back. The examples run without one, and what the script
  # stored is destroyed afterwards, with its file.
  self.use_transactional_tests = false

  around do |example|
    already_stored = ActionMailbox::InboundEmail.ids
    example.run
  ensure
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
      ActionMailbox::InboundEmail.where.not(id: already_stored).destroy_all
    end
  end

  around do |example|
    ENV['DISABLE_DEPRECATION_WARNINGS'] = 'true'
    example.call
    ENV['DISABLE_DEPRECATION_WARNINGS'] = nil
  end

  it "should not produce any output and should return a 0 code on importing a plain email" do
    r = mailin_test("incoming-request-empty.eml")
    expect(r.status).to eq(0)
    expect(r.out).to eq("")
  end
end
