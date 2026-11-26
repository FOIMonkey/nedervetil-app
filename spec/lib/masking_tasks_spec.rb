require 'spec_helper'
require 'rake'

RSpec.describe 'masking:retry_faults' do
  include ActiveJob::TestHelper

  before(:all) do
    unless Rake::Task.task_defined?('masking:retry_faults')
      Rails.application.load_tasks
    end
  end

  def run
    Rake::Task['masking:retry_faults'].reenable
    Rake::Task['masking:retry_faults'].invoke
  end

  it 'masks again each part whose masking hit a fault, and only those' do
    faulted = FactoryBot.create(:pdf_attachment)
    faulted.update_columns(masking_failed_at: Time.current)
    FactoryBot.create(:pdf_attachment)
    erased = FactoryBot.create(:pdf_attachment)
    erased.update_columns(masking_failed_at: Time.current,
                          erased_at: Time.current)

    expect { run }.
      to output("Queued 1 part to be masked again\n").to_stdout.
      and have_enqueued_job(FoiAttachment::MaskJob).with(faulted).
      exactly(:once)
    expect(FoiAttachment::MaskJob).
      not_to have_been_enqueued.with(erased)
  end
end
