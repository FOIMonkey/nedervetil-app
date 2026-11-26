# Standalone real-Redis integration check; never run against application Redis.
# GEM_HOME/GEM_PATH must contain both Sidekiq versions below and redis 6.0.0,
# which worker_fixture.rb activates; redis is not in the app's bundle.
require 'uri'
unless URI(ENV.fetch('REDIS_URL')).host == 'sidekiq7-redis'
  raise 'Use the disposable sidekiq7-redis service only'
end

require 'redis'
require 'json'
require 'rbconfig'
require 'timeout'
require 'tempfile'
OLD = '7.3.10'.freeze
NEW = '8.1.7'.freeze
FIXTURE = File.expand_path('worker_fixture.rb', __dir__)
R = Redis.new(url: ENV.fetch('REDIS_URL'))
# Each worker's pid is added when it starts and removed when it stops.
PIDS = [] # rubocop:disable Style/MutableConstant
def check(value, message)
  raise message unless value

  puts "PASS: #{message}"
end

def eventually(message, seconds: 30)
  Timeout.timeout(seconds) do
    until yield
      PIDS.each do |pid|
        if Process.waitpid(pid, Process::WNOHANG)
          raise "worker exited before #{message}"
        end
      end
      sleep 0.05
    end
  end
  puts "PASS: #{message}"
end

def producer(version, code)
  ok = system({ 'SIDEKIQ_TEST_VERSION' => version },
              RbConfig.ruby, '-r', FIXTURE, '-e', code)
  raise "producer #{version} failed" unless ok
end

def worker(version, suffix)
  log = File.join(ENV.fetch("SIDEKIQ_TEST_LOG_DIR", "/tmp"),
                  "sidekiq-upgrade-#{suffix}.log")
  pid = Process.spawn(
    { 'SIDEKIQ_TEST_VERSION' => version }, RbConfig.ruby, '-r', FIXTURE, '-e',
    'Sidekiq::CLI.instance.parse(["-r", ARGV[0], "-C", ARGV[1], ' \
    '"-t", "2"]); Sidekiq::CLI.instance.run',
    FIXTURE, File.expand_path('queues.yml', __dir__),
    out: log, err: [:child, :out]
  )
  PIDS << pid
  pid
end

def stop(pid)
  Process.kill('TERM', pid)
  Timeout.timeout(15) { Process.wait(pid) }
  PIDS.delete(pid)
rescue Errno::ESRCH, Errno::ECHILD
  PIDS.delete(pid)
end
begin
  [[OLD, NEW], [NEW, OLD], [NEW, NEW]].each_with_index do |(from, to), n|
    R.flushdb
    producer(from, <<~CODE)
      UpgradeActiveJob.perform_later(UpgradeRecord.new('42'), 'Welsh: ŵ — test')
      2.times { UpgradeUniqueJob.perform_later('unique') }
      2.times { UpgradeExecutingJob.perform_later }
      UpgradeMailer.notice.deliver_later
      UpgradeDeadWorker.perform_async
      UpgradeWorker.perform_in(1, 'scheduled')
      UpgradeWorker.perform_in(3600, 'future')
      UpgradeWorker.perform_async('retry', 0, true)
      8.times { |i| UpgradeLowWorker.perform_async("low-\#{i}", 0.15) }
      8.times { |i| UpgradeLimitedWorker.perform_async("limited-\#{i}", 0.15) }
    CODE
    check(R.llen('queue:default') == 6,
          "#{from} deduplicates ActiveJob enqueue")
    original = R.lrange('queue:default', 0, -1).map { |j| JSON.parse(j)['jid'] }
    future = R.zrange('schedule', 0, -1, with_scores: true).find do |j, _|
      JSON.parse(j)['args'] == ['future']
    end
    a = worker(to, "#{n}-a")
    b = worker(n == 2 ? OLD : to, "#{n}-b")
    eventually('unique job starts under consumer version') do
      R.lrange('test:started', 0, -1).include?('executing-unique')
    end
    producer(to, 'UpgradeExecutingJob.perform_later')
    eventually("#{from} payloads consumed by #{to}") do
      R.llen('test:results') >= 21
    end
    eventually('failed job retained with original JID and retry count') do
      R.zrange('retry', 0, -1).any? do |j|
        h = JSON.parse(j)
        original.include?(h['jid']) && h['retry_count'] == 0
      end
    end
    producer(to, 'Sidekiq::RetrySet.new.each(&:retry)')
    eventually('retry executes successfully') do
      R.lrange('test:results', 0, -1).include?('retry')
    end
    values = R.lrange('test:results', 0, -1)
    check(values.include?('mail-captured'),
          'queued ActionMailer delivers to local capture')
    check(R.zrange('schedule', 0, -1, with_scores: true).include?(future),
          'future payload and due time remain unchanged')
    eventually('exhausted job retained in dead set') { R.zcard('dead') == 1 }
    check(values.count('executing-unique') == 1,
          'until_and_while_executing prevents duplicates while running')
    check(values.count('unique') == 1, 'unique job executes once')
    check(values.include?('42:Welsh: ŵ — test'),
          'GlobalID and UTF-8 arguments survive')
    check(R.lrange('test:counts', 0, -1).
            grep(/^Upgrade(?:Limited|Low)Worker:/).
            all? { |x| x.end_with?(':1') },
          'global queue limit holds across two workers')
    stop(a)
    stop(b)
    producer(to, "UpgradeUniqueJob.perform_later('unique')")
    check(R.llen('queue:default') == 1,
          'uniqueness lock released after execution')
  end
  R.flushdb
  a = worker(NEW, 'shutdown')
  producer(NEW, "UpgradeWorker.perform_async('interrupted', 10)")
  eventually('long job started') do
    R.lrange('test:started', 0, -1).include?('interrupted')
  end
  Process.kill('TSTP', a)
  producer(NEW, "UpgradeWorker.perform_async('after-quiet')")
  sleep 0.3
  check(!R.lrange('test:started', 0, -1).include?('after-quiet'),
        'quiet worker does not fetch new jobs')
  stop(a)
  check(R.llen('queue:default') == 2,
        'shutdown requeues unfinished job and preserves pending work')
  b = worker(NEW, 'restart')
  eventually('restart finishes both jobs', seconds: 25) do
    R.llen('test:results') == 2
  end
  stop(b)
  puts 'All real-worker compatibility checks passed.'
ensure
  PIDS.dup.each { |pid| stop(pid) }
end
