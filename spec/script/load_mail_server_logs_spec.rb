require 'spec_helper'
require 'external_command'

RSpec.describe 'when importing mail logs into the application' do
  around do |example|
    ENV['DISABLE_DEPRECATION_WARNINGS'] = 'true'
    example.call
    ENV['DISABLE_DEPRECATION_WARNINGS'] = nil
  end

  def load_mail_server_logs_test(log_file = nil)
    Dir.chdir Rails.root do
      ExternalCommand.new('script/load-mail-server-logs', *log_file).run
    end
  end

  context 'without log file argument' do
    it 'should not produce any output and should return a 0 code' do
      r = load_mail_server_logs_test
      expect(r.status).to eq(0)
      expect(r.err).to eq('')
      expect(r.out).to eq('')
    end
  end

  context 'with log file' do
    it 'should not produce any output and should return a 0 code' do
      log = file_fixture_name('exim-mainlog-2016-04-28')
      r = load_mail_server_logs_test(log.to_s)
      expect(r.status).to eq(0)
      expect(r.err).to eq('')
      expect(r.out).to eq('')
    end
  end

  context 'with missing log file' do
    it 'should output no such file error' do
      r = load_mail_server_logs_test('missing')
      expect(r.err).to include('No such file or directory')
    end
  end

  # With no pattern, ls listed the script's own app directory and the last
  # three entries were loaded as mail logs. These run a copy of the script
  # beside a stand-in bin/config, with a stand-in bundle that records calls.
  context 'when MTA_LOG_PATH cannot be used' do
    def run_with_config(config_body)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(%W[#{dir}/script #{dir}/bin #{dir}/fakebin])
        FileUtils.cp(Rails.root.join('script/load-mail-server-logs'),
                     "#{dir}/script/")
        File.write("#{dir}/bin/config", "#!/bin/sh\n#{config_body}\n")
        File.write("#{dir}/fakebin/bundle",
                   "#!/bin/sh\necho \"$*\" >> #{dir}/bundle-calls\n")
        FileUtils.chmod(0o755, %W[#{dir}/bin/config #{dir}/fakebin/bundle])
        r = ExternalCommand.new(
          "#{dir}/script/load-mail-server-logs",
          env: { 'PATH' => "#{dir}/fakebin:#{ENV.fetch('PATH')}" }
        ).run
        yield r, File.exist?("#{dir}/bundle-calls")
      end
    end

    it 'stops without loading anything when bin/config fails' do
      run_with_config("echo 'no general.yml' >&2; exit 1") do |r, loaded|
        expect(r.status).to eq(1)
        expect(r.err).to include('no general.yml')
        expect(loaded).to eq(false)
      end
    end

    it 'stops without loading anything when the setting is blank' do
      run_with_config('echo') do |r, loaded|
        expect(r.status).to eq(1)
        expect(r.err).to eq("MTA_LOG_PATH is blank\n")
        expect(loaded).to eq(false)
      end
    end
  end
end
