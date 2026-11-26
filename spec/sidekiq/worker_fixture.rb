# Loaded in a separate process for each supported Sidekiq version.
gem 'sidekiq', ENV.fetch('SIDEKIQ_TEST_VERSION')
gem 'redis', '6.0.0'
require 'rails'
require 'sidekiq'
require 'sidekiq/cli'
require 'sidekiq/api'
require 'sidekiq-limit_fetch'
require 'redis'
require 'redis-client'
require 'active_job'
require 'sidekiq/rails'
require 'active_job/uniqueness'
require 'globalid'
require 'logger'
GlobalID.app = 'sidekiq-upgrade-test'
ActiveJob::Base.logger = Logger.new(File::NULL)
Sidekiq.configure_client { |c| c.redis = { url: ENV.fetch('REDIS_URL') } }
Sidekiq.configure_server do |c|
  c.redis = { url: ENV.fetch('REDIS_URL') }
  c[:poll_interval_average] = 1
end
ActiveJob::Base.queue_adapter = :sidekiq
ActiveJob::Uniqueness.configure do |c|
  c.redlock_servers = [
    RedisClient.config(url: ENV.fetch('REDIS_URL')).new_client
  ]
end
class UpgradeRecord
  include GlobalID::Identification
  attr_reader :id

  def initialize(id)
    @id = id
  end

  def self.find(id)
    new(id)
  end
end

class UpgradeActiveJob < ActiveJob::Base
  queue_as :default
  def perform(record, text)
    Redis.new(url: ENV.fetch('REDIS_URL')).
      rpush('test:results', "#{record.id}:#{text}")
  end
end

class UpgradeUniqueJob < ActiveJob::Base
  queue_as :default
  unique :until_executed, on_conflict: :log
  def perform(text)
    Redis.new(url: ENV.fetch('REDIS_URL')).rpush('test:results', text)
  end
end

class UpgradeWorker
  include Sidekiq::Worker
  sidekiq_options retry: 2
  def perform(token, duration = 0, fail_once = false)
    redis = Redis.new(url: ENV.fetch('REDIS_URL'))
    count = redis.incr("test:active:#{self.class.name}")
    redis.rpush('test:counts', "#{self.class.name}:#{count}")
    redis.rpush('test:started', token)
    sleep duration
    if fail_once && redis.incr("test:attempts:#{token}") == 1
      raise 'synthetic retry'
    end

    redis.rpush('test:results', token)
  ensure
    redis&.decr("test:active:#{self.class.name}")
  end
end

class UpgradeLimitedWorker < UpgradeWorker
  sidekiq_options queue: 'low'
end

require 'action_mailer'
class UpgradeMailer < ActionMailer::Base
  self.delivery_method = :test
  self.deliver_later_queue_name = :default
  after_deliver do
    Redis.new(url: ENV.fetch('REDIS_URL')).
      rpush('test:results', 'mail-captured')
  end
  def notice
    mail(from: 'sender@example.test', to: 'recipient@example.test',
         subject: 'Synthetic upgrade check', body: 'Local capture only')
  end
end

class UpgradeLowWorker < UpgradeWorker
  sidekiq_options queue: 'low'
end

class UpgradeDeadWorker < UpgradeWorker
  sidekiq_options retry: 0
  def perform
    raise 'synthetic exhausted job'
  end
end

class UpgradeExecutingJob < ActiveJob::Base
  queue_as :default
  unique :until_and_while_executing, on_conflict: :log
  def perform
    redis = Redis.new(url: ENV.fetch('REDIS_URL'))
    redis.rpush('test:started', 'executing-unique')
    sleep 3
    redis.rpush('test:results', 'executing-unique')
  end
end
