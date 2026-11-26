require 'spec_helper'

RSpec.describe 'health checks' do
  before do
    # create recent content to satisfy checks.
    FactoryBot.create(:user)
    FactoryBot.create(:info_request)
    FactoryBot.create(:incoming_message)
  end

  def status
    get '/health/checks'
    response.status
  end

  it { expect(status).to eq 200 }
end
