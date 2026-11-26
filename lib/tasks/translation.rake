require File.join(File.dirname(__FILE__), 'usage')
namespace :translation do
  include Usage

  def write_email(email, email_description, output_file)
    mail_object = Mail.from_source(email.to_s)
    output_file.write("\n")
    output_file.write("Description of email: #{email_description}\n")
    output_file.write("Subject line: #{mail_object.subject}\n")
    output_file.write("\n")
    if mail_object.parts.empty?
      mail_object.header.fields.each do |field|
        output_file.write("#{field.name}: #{Mail::Encodings.value_decode(field)}\n")
      end
      output_file.write("\n")
      output_file.write(mail_object.decoded)
    else
      mail_object.parts.each do |part|
        output_file.write("Message part **\n")
        output_file.write(part.body.to_s)
      end
    end
    output_file.write("\n")
    output_file.write("********\n")
  end

  desc "Create previews of translated emails"
  task preview_emails: :environment do
    check_for_env_vars(%w[INFO_REQUEST_ID
                          FOLLOW_UP_ID
                          INCOMING_MESSAGE_ID
                          DIR], nil)
    info_request = InfoRequest.find(ENV.fetch('INFO_REQUEST_ID', nil))
    if info_request.outgoing_messages.empty?
      raise "Info request #{info_request.id} does not have any " \
            "outgoing messages"
    end

    initial_request = info_request.outgoing_messages.first
    follow_up = OutgoingMessage.find(ENV.fetch('FOLLOW_UP_ID', nil))
    incoming_message =
      IncomingMessage.find(ENV.fetch('INCOMING_MESSAGE_ID', nil))

    output_path = File.join(ENV.fetch('DIR', nil), 'message_preview.txt')
    output_file = File.open(output_path, 'w')

    # outgoing mailer
    request_email = OutgoingMailer.initial_request(info_request,
                                                   initial_request)
    write_email(request_email, 'Initial Request', output_file)

    followup_email = OutgoingMailer.followup(info_request, follow_up, nil)
    write_email(followup_email, 'Follow up', output_file)

    # contact mailer
    contact_email = ContactMailer.to_admin_message(info_request.user_name,
                                                   info_request.user.email,
                                                   'A test message',
                                                   'Hello!',
                                                   info_request.user,
                                                   info_request,
                                                   info_request.public_body)

    write_email(contact_email, 'Contact email (to admin)', output_file)

    admin_contact_email = ContactMailer.from_admin_message(
      info_request.user.name,
      info_request.user.email,
      'A test message',
      'Hello!'
    )
    write_email(admin_contact_email,
                'Contact email (admin to user)',
                output_file)

    # request mailer
    fake_response_email = RequestMailer.fake_response(info_request,
                                                      info_request.user,
                                                      "test body",
                                                      "attachment.txt",
                                                      "test attachment text")
    write_email(fake_response_email,
                'Email created when someone uploads a response directly',
                output_file)

    content = File.read(File.join(Rails.root,
                                  'spec',
                                  'fixtures',
                                  'files',
                                  'incoming-request-plain.email'))
    response_mail = Mail.from_source(content)

    response_mail.from = "authority@example.com"
    stopped_responses_email = RequestMailer.stopped_responses(info_request,
                                                              response_mail)
    write_email(stopped_responses_email,
                'Bounce if someone sends email to a request that has had ' \
                'responses stopped',
                output_file)

    requires_admin_email = RequestMailer.requires_admin(info_request)
    write_email(requires_admin_email,
                'Drawing admin attention to a response',
                output_file)

    new_response_email = RequestMailer.new_response(info_request,
                                                    incoming_message)
    write_email(new_response_email,
                'Telling the requester that a new response has arrived',
                output_file)

    # user mailer
    site_name = AlaveteliConfiguration.site_name
    reasons = {
      web: "",
      email: _("Then you can sign in to {{site_name}}", site_name: site_name),
      email_subject: _("Confirm your account on {{site_name}}",
                       site_name: site_name)
    }
    confirm_login_email = UserMailer.confirm_login(info_request.user,
                                                   reasons,
                                                   'http://www.example.com')
    write_email(confirm_login_email, 'Confirm a user login', output_file)

    already_registered_email = UserMailer.already_registered(
      info_request.user,
      reasons,
      'http://www.example.com'
    )
    write_email(already_registered_email,
                'Tell a user they are already registered',
                output_file)

    new_email = 'new_email@example.com'
    changeemail_confirm_email = UserMailer.changeemail_confirm(
      info_request.user,
      new_email,
      'http://www.example.com'
    )
    write_email(changeemail_confirm_email,
                'Confirm that the user wants to change their email',
                output_file)

    changeemail_already_used = UserMailer.changeemail_already_used(
      'old_email@example.com',
      new_email
    )
    write_email(changeemail_already_used,
                'Tell a user that the email they want to change to is ' \
                'already used',
                output_file)

    output_file.close
  end
end
