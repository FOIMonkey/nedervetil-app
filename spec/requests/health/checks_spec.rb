require 'spec_helper'

RSpec.describe 'Health checks page', type: :request do
  describe 'GET index' do
    it 'returns a 200 if all health checks pass' do
      allow(HealthChecks).to receive_messages(ok?: true)
      get health_checks_path
      expect(response).to have_http_status(200)
    end

    it 'returns a 500 if the health check fails' do
      allow(HealthChecks).to receive_messages(ok?: false)
      get health_checks_path
      expect(response).to have_http_status(500)
    end

    it 'does not render a layout' do
      get health_checks_path
      expect(response.body).to include('<h1>Health Checks</h1>')
      expect(response.body).not_to include('<html')
      expect(response.body).not_to include('<body')
    end
  end
end
