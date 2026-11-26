require 'spec_helper'
require 'rake'

# The tasks config/crontab-example schedules.
RSpec.describe 'Maintenance tasks' do
  before(:all) do
    unless Rake::Task.task_defined?('documents:clean_up')
      Rails.application.load_tasks
    end
  end

  def run(name)
    Rake::Task[name].reenable
    Rake::Task[name].invoke
  end

  it 'clears expired attachment edits, then expired regulator packs' do
    expect(AttachmentManagement::CleanupJob).to receive(:perform_now).ordered
    expect(RegulatorPack).to receive(:purge_expired!).ordered
    run('documents:clean_up')
  end

  it 'checks failed readings again and fetches regulators’ decisions, saying what it did' do
    allow(IncomingAttention::Recovery).to receive(:run).and_return(2)
    allow(AuthorityFeeds::Fetch).
      to receive(:run).and_return({ 'ico_decisions' => 3 })
    expect { run('incoming_attention:recover') }.to output("2\n").to_stdout
    expect { run('authority_feeds:fetch') }.
      to output("{\"ico_decisions\":3}\n").to_stdout
  end
end
