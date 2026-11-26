namespace :users do
  desc 'CSV containing count of users per email domain, most popular first'
  task count_per_domain: :environment do
    from = ENV.fetch("START_DATE", nil)

    results = UserStats.list_user_domains(start_date: from)

    puts %w(domain count_of_users).to_csv

    results.each do |result|
      puts [result['domain'], result['count']].to_csv
    end
  end

  desc "Lists per domain stats"
  task stats_by_domain: :environment do
    raise "must supply a DOMAIN value" unless ENV["DOMAIN"]

    domain = ENV.fetch("DOMAIN", nil)
    from = ENV.fetch("START_DATE", nil)

    users = User.where("email like ?", "%@#{domain}")
    users = users.where("created_at >= ?", from) if from

    total_users = users.count
    banned = users.banned.count

    banned_percent = if total_users == 0
                       0
                     else
                       (banned.to_f / total_users * 100).round(2)
                     end

    dormant = UserStats.count_dormant_users(domain, from)

    dormant_percent = if total_users == 0
                        0
                      else
                        (dormant.to_f / total_users * 100).round(2)
                      end

    p "Since #{from}..." if from
    p "total users: #{total_users}"
    p "   banned %: #{banned} (#{banned_percent}%)"
    p "  dormant %: #{dormant} (#{dormant_percent}%)"
  end

  desc "Bans all users for a specific domain"
  task ban_by_domain: :environment do
    raise "must supply a DOMAIN value" unless ENV["DOMAIN"]

    domain = ENV.fetch("DOMAIN", nil)
    from = ENV.fetch("START_DATE", nil)

    Rake.application.invoke_task("users:stats_by_domain")

    p ""

    message = "Do you want to ban all the non-admin users for #{domain}"
    message += " created on or after #{from}" if from
    message += "(y/N)"
    p message
    input = STDIN.gets.strip

    if input.downcase == "y"
      to_ban = UserStats.unbanned_by_domain(domain, from)
      count = to_ban.
        update_all(ban_text: "Banned for spamming")
      p "#{count} accounts banned"
    else
      p "No action taken"
    end
  end

  desc 'Destroy user accounts that have not created any content'
  task destroy_unused: :environment do
    time_range = ...2.years.ago
    users = User.unused.where(
      created_at: time_range, last_sign_in_at: [nil, time_range]
    )
    count = users.count

    progressbar = ProgressBar.create(
      title: "Destroying unused user accounts",
      total: count,
      format: '%t: %c/%C |%w>%i| %e'
    ) if Rake.verbose

    ActiveRecord::Base.logger.silence do
      users.preload(
        User.reflect_on_all_associations.map(&:name)
      ).in_batches.each_record do |user|
        user.destroy
        progressbar&.increment
      end
    end

    progressbar&.finish
    puts("Destroying unused user accounts completed.") if Rake.verbose
  end
end
