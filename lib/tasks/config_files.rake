require File.join(File.dirname(__FILE__), 'usage')
namespace :config_files do
  include Usage

  desc 'Set reject_incoming_at_mta on old requests that are rejecting ' \
       'incoming mail'
  task set_reject_incoming_at_mta: :environment do
    example = 'rake config_files:set_reject_incoming_at_mta ' \
              'REJECTED_THRESHOLD=5 AGE_IN_MONTHS=12'
    check_for_env_vars(%w[REJECTED_THRESHOLD AGE_IN_MONTHS], example)
    dryrun = ENV['DRYRUN'] != '0'
    STDERR.puts "Only a dry run; info_requests will not be updated" if dryrun
    options = { rejection_threshold: ENV['REJECTED_THRESHOLD'].to_i,
                age_in_months: ENV['AGE_IN_MONTHS'].to_i,
                dryrun: dryrun }

    updated_count = InfoRequest.reject_incoming_at_mta(options) do |ids|
      puts "Info Request\tRejected incoming count\tLast updated"
      ids.each do |id|
        info_request = InfoRequest.find(id)
        puts "#{info_request.id}\t#{info_request.rejected_incoming_count}\t" \
             "#{info_request.updated_at}"
      end
    end
    puts "Updated #{updated_count} info requests"
  end

  desc 'Set reject_incoming_at_mta on a list of requests identified by ' \
       'request address'
  task set_reject_incoming_at_mta_from_list: :environment do
    example = 'rake config_files:set_reject_incoming_at_mta_from_list ' \
              'FILE=/tmp/rejection_list.txt'

    check_for_env_vars(['FILE'], example)

    File.read(ENV.fetch('FILE', nil)).each_line do |line|
      info_request = InfoRequest.find_by_incoming_email(line.strip)
      info_request.reject_incoming_at_mta = true
      info_request.save!
    end
  end

  desc 'Unset reject_incoming_at_mta on a request'
  task unset_reject_incoming_at_mta: :environment do
    example = 'rake config_files:unset_reject_incoming_at_mta REQUEST_ID=4'
    check_for_env_vars(['REQUEST_ID'], example)
    info_request = InfoRequest.find(ENV.fetch('REQUEST_ID', nil))
    if info_request.reject_incoming_at_mta
      info_request.reject_incoming_at_mta = false
      info_request.allow_new_responses_from = 'authority_only'
      info_request.save!
      puts "reject_incoming_at_mta set to false for InfoRequest " \
           "#{ENV.fetch('REQUEST_ID', nil)}"
    else
      puts "Warning: reject_incoming_at_mta already false for " \
           "InfoRequest #{ENV.fetch('REQUEST_ID', nil)}"
    end
  end

  desc 'Produce a list of email addresses for which the MTA should reject ' \
       'messages at RCPT time'
  task generate_mta_rejection_list: :environment do
    example = 'rake config_files:generate_mta_rejection_list MTA=(exim|postfix)'
    check_for_env_vars(['MTA'], example)
    mta = ENV['MTA'].downcase
    unless %w[postfix exim].include? mta
      puts "Error: Unrecognised MTA"
      exit 1
    end
    InfoRequest.where(reject_incoming_at_mta: true).each do |info_request|
      if mta == 'postfix'
        puts "#{info_request.incoming_email} REJECT"
      else
        puts info_request.incoming_email
      end
    end
  end

  desc 'Set the Rails credentials, adding any that are missing'
  task set_credentials: :environment do
    require "active_support/encrypted_configuration"

    # Generate the master key on first run so a single command can bootstrap the
    # credentials, the same way `rails credentials:edit` would.
    master_key = Rails.root.join("config/master.key")
    unless master_key.exist? || ENV["RAILS_MASTER_KEY"]
      master_key.write(ActiveSupport::EncryptedFile.generate_key)
    end

    encrypted_file = ActiveSupport::EncryptedConfiguration.new(
      config_path: "config/credentials.yml.enc",
      key_path: "config/master.key",
      env_key: "RAILS_MASTER_KEY",
      raise_if_missing_key: true
    )

    # Add only what is missing, generating any value not supplied through the
    # environment. Existing values are left untouched, so this is safe to run
    # repeatedly and against credentials set up another way.
    existing = YAML.safe_load(encrypted_file.read) || {}

    blocks = []

    unless existing.key?("secret_key_base")
      secret_key_base = ENV.fetch("SECRET_KEY_BASE") do
        configured = AlaveteliConfiguration.secret_key_base
        if AlaveteliConfiguration.default_secret?(configured)
          SecureRandom.hex(64)
        else
          configured
        end
      end
      blocks << "secret_key_base: #{secret_key_base}"
    end

    unless existing.dig("action_mailbox", "ingress_password")
      ingress_password =
        ENV.fetch("INGRESS_PASSWORD") { SecureRandom.alphanumeric(24) }
      blocks << <<~YAML.chomp
        action_mailbox:
          ingress_password: #{ingress_password}
      YAML

      puts "\e[1;33m" \
        "ActionMailbox ingress password: #{ingress_password}\n" \
        "Set this same value in your MTA (Postfix/Exim) configuration." \
        "\e[0m"
    end

    unless existing.key?("active_record_encryption")
      blocks << <<~YAML.chomp
        active_record_encryption:
          primary_key: #{SecureRandom.alphanumeric(32)}
          deterministic_key: #{SecureRandom.alphanumeric(32)}
          key_derivation_salt: #{SecureRandom.alphanumeric(32)}
      YAML
    end

    next if blocks.empty?

    encrypted_file.change do |tmp_path|
      parts = ([File.read(tmp_path).chomp] + blocks).reject(&:empty?)
      File.write(tmp_path, parts.join("\n") + "\n")
    end

    puts "\e[1;33m" \
      "IMPORTANT: back up config/master.key and config/credentials.yml.enc " \
      "now, somewhere safe and separate from the server. Without " \
      "config/master.key the credentials, and every database column " \
      "encrypted with them, cannot be read." \
      "\e[0m"
  end
end
