require "spec_helper"
require "external_command"

def mail_reply_test(email_filename, raw: load_file_fixture(email_filename))
  Dir.chdir Rails.root do
    xc = ExternalCommand.new("script/handle-mail-replies", "--test",
                             stdin_string: raw)
    xc.run
    expect(xc.err).to eq("")
    return xc
  end
end

RSpec.describe "When filtering" do
  around do |example|
    ENV['DISABLE_DEPRECATION_WARNINGS'] = 'true'
    example.call
    ENV['DISABLE_DEPRECATION_WARNINGS'] = nil
  end

  describe "when not in test mode" do
    it "should not fail handling a bounce mail" do
      xc = ExternalCommand.new(
        "script/handle-mail-replies",
        { stdin_string: load_file_fixture("track-response-exim-bounce.eml") }
      )
      xc.run
      expect(xc.err).to eq("")
    end

    # Runs the script itself with a stand-in for sendmail, so the forward
    # goes down a pipe without waiting on a mail server.
    def forward_live(email_filename, env = {})
      Dir.mktmpdir do |dir|
        out = File.join(dir, 'forwarded')
        raw = load_file_fixture(email_filename)
        xc = ExternalCommand.new(
          'bundle', 'exec', 'ruby', '-W0',
          '-r', Rails.root.join('spec/script/stub_sendmail.rb').to_s,
          Rails.root.join('script/handle-mail-replies.rb').to_s,
          env: env.merge('STUB_SENDMAIL_OUT' => out),
          stdin_string: raw
        )
        Dir.chdir(Rails.root) { xc.run }
        expect(xc.err).to eq("")
        expect(xc.status).to eq(0)
        expect(File.read("#{out}.cmd")).
          to eq(JSON.generate(['/usr/sbin/sendmail', '-i', '--',
                               'user-support@localhost']))
        expect(File.binread(out)).to eq(raw)
      end
    end

    it 'should not fail handling a UTF8 encoded mail' do
      forward_live('russian.eml')
    end

    it "should pass on a non-bounce message with Received headers" do
      forward_live('apple-mail-with-attachments.eml')
    end
  end

  it "should detect an Exim bounce" do
    r = mail_reply_test("track-response-exim-bounce.eml")
    expect(r.status).to eq(1)
    expect(r.out).to eq("user@example.com\n")
  end

  it "should detect a WebShield delivery error message with null return-path" do
    raw = load_file_fixture("track-response-webshield-bounce.eml").sub(
      /^Return-Path: <[^>]+>/, "Return-Path: <>"
    )
    r = mail_reply_test("track-response-webshield-bounce.eml", raw: raw)
    expect(r.status).to eq(1)
    expect(r.out).to eq("failed.user@example.co.uk\n")
  end

  it "should ignore a WebShield subject without null return-path or Auto-Submitted" do
    r = mail_reply_test("track-response-webshield-bounce.eml")
    expect(r.status).to eq(0)
    expect(r.out).to eq("")
  end

  it "should detect a MS Exchange non-permanent delivery error message" do
    r = mail_reply_test("track-response-ms-bounce.eml")
    expect(r.status).to eq(1)
    expect(r.out).to eq("")
  end

  it "should pass on a non-bounce message" do
    r = mail_reply_test("incoming-request-bad-uuencoding.eml")
    expect(r.status).to eq(0)
    expect(r.out).to eq("")
  end

  it "should detect a multipart bounce" do
    r = mail_reply_test("track-response-multipart-report.eml")
    expect(r.status).to eq(1)
    expect(r.out).to eq("FailedUser@example.com\n")
  end

  it "should detect a generic out-of-office" do
    r = mail_reply_test("track-response-generic-oof.eml")
    expect(r.status).to eq(2)
  end

  it "should detect an Exchange-style out-of-office" do
    r = mail_reply_test("track-response-exchange-oof-1.eml")
    expect(r.status).to eq(2)
  end

  it "should detect a Lotus Domino-style out-of-office" do
    r = mail_reply_test("track-response-lotus-oof-1.eml")
    expect(r.status).to eq(2)
  end

  it "should detect a Messagelabs-style out-of-office" do
    r = mail_reply_test("track-response-messagelabs-oof-1.eml")
    expect(r.status).to eq(2)
  end

  it "should detect an out-of-office that has an X-POST-MessageClass header" do
    r = mail_reply_test("track-response-messageclass-oof.eml")
    expect(r.status).to eq(2)
  end

  it "should detect an Outlook(?)-style out-of-office" do
    r = mail_reply_test("track-response-outlook-oof.eml")
    expect(r.status).to eq(2)
  end

  it "should detect an ABCMail-style out-of-office" do
    r = mail_reply_test("track-response-abcmail-oof.eml")
    expect(r.status).to eq(2)
  end
end
