require 'spec_helper'

RSpec.describe 'Health metrics page', type: :request do
  describe 'GET index' do
    before { get health_metrics_path }

    it 'returns a 200' do
      expect(response).to have_http_status(200)
    end

    it 'shows the sidekiq stats' do
      %w[sidekiq_processed_job sidekiq_busy_workers sidekiq_enqueued_jobs
         sidekiq_retry_jobs sidekiq_scheduled_jobs sidekiq_failed_jobs
         sidekiq_dead_jobs].each do |metric|
        expect(response.body).to match(/^#{metric} \d+$/)
      end
    end

    it 'does not render a layout' do
      expect(response.body).to start_with('# HELP sidekiq_processed_jobs')
      expect(response.body).not_to include('<html')
    end
  end
end
