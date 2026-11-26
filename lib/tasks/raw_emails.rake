namespace :raw_emails do
  desc 'Purge raw emails older than 120 days after request last activity'
  task purge_expired: :environment do
    RawEmail.purge_expired!
  end
end
