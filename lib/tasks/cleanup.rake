namespace :cleanup do
  desc 'Clean up all message redelivery and destroy actions from the ' \
       'holding pen to make admin actions there faster'
  task holding_pen: :environment do
    dryrun = ENV['DRYRUN'] != '0' if ENV['DRYRUN']
    $stderr.puts "This is a dryrun - nothing will be deleted" if dryrun
    holding_pen = InfoRequest.holding_pen_request
    holding_pen.info_request_events.
      where(event_type: %w(redeliver_incoming destroy_incoming)).
        find_each do |event|
      $stderr.puts event.inspect if verbose || dryrun
      event.destroy unless dryrun
    end
  end

  desc 'Export of last 2 days of requests to search for spam'
  task spam_requests: :environment do
    str = CSV.generate do |csv|
      # Make headers
      csv << %w[
        info_request_id
        info_request_title
        user_id
        public_body_id
        public_body_name
        public_body_request_email
        created_at
      ]

      # Add rows
      InfoRequest.where(
        created_at: [2.days.ago..Time.zone.now]
      ).find_each do |request|
        csv << [
          request.id,
          request.title,
          request.user_id,
          request.public_body_id,
          request.public_body.name,
          request.public_body.request_email,
          request.created_at.to_s
        ]
      end
    end

    puts str
  end
end
