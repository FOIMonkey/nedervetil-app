# Loads invented development/demo data through the models (bin/rails
# sample_data:load; see doc/FORK.md). Refuses production or non-empty DBs.
module SampleData
  PASSWORD = 'jonespassword'.freeze
  ACCOUNTS = [
    ['Requester', 'requester@example.org'],
    ['Admin', 'admin@example.org'],
    ['Admin with every role', 'annie@localhost']
  ].freeze
  HOLIDAYS = { [1, 1] => 'New Year’s Day', [12, 25] => 'Christmas Day',
               [12, 26] => 'Boxing Day' }.freeze
  Refused = Class.new(StandardError)

  module_function

  def load!(out: $stdout)
    if Rails.env.production?
      raise Refused, 'Sample data is for development only.'
    end
    if data?
      raise Refused, 'The database already has data. Sample data loads only ' \
                     'into an empty one; run docker/reset to start again.'
    end

    # Roles and Pro's request summary categories; seeds are repeatable.
    Rails.application.load_seed
    quietly do
      # The topics, before the documents that match them.
      Topics.load!
      Dataset.new(out).build
      holidays!
    end
    [PublicBody, User, InfoRequest, InfoRequestEvent, OutgoingMessage,
     PublicBodyChangeRequest].each(&:reindex_all)
  end

  # The public holidays that fall on the same date every year, for this year
  # and the next two, so a deadline worked out on a demo skips them.
  def holidays!(year = Time.zone.today.year)
    (year..(year + 2)).each do |each_year|
      HOLIDAYS.each do |(month, day), name|
        Holiday.create!(day: Date.new(each_year, month, day),
                        description: name)
      end
    end
  end

  # Shared with docker/setup to decide whether the database is already seeded.
  def data?
    User.where.not(email: AlaveteliConfiguration.contact_email).exists? ||
      PublicBody.exists? || InfoRequest.exists?
  end

  def accounts
    ACCOUNTS.map { |role, email| "#{role}: #{email} / #{PASSWORD}" }
  end

  # Suppresses outbound mail, job queueing and request limits while loading.
  def quietly
    deliveries = ActionMailer::Base.perform_deliveries
    adapter = ActiveJob::Base.queue_adapter
    limits = RequestLimits.enforced
    ActionMailer::Base.perform_deliveries = false
    ActiveJob::Base.queue_adapter = :test
    RequestLimits.enforced = false
    yield
  ensure
    ActionMailer::Base.perform_deliveries = deliveries
    ActiveJob::Base.queue_adapter = adapter
    RequestLimits.enforced = limits
  end

  # Local-only jobs safe to run during load (excludes outbound mail and AI).
  LOCAL_JOBS = %w[IncomingMessage::StoreTextJob FoiAttachment::MaskJob
                  Disclosures::SuggestJob].freeze

  def run_local_jobs
    queued = ActiveJob::Base.queue_adapter.enqueued_jobs
    loop do
      jobs = queued.select { |job| LOCAL_JOBS.include?(job['job_class']) }
      break if jobs.empty?

      queued.replace(queued - jobs)
      jobs.each { |job| ActiveJob::Base.execute(job) }
    end
  end
end
