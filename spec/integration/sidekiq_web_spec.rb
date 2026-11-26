require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'Sidekiq administration' do
  it 'does not expose the dashboard to visitors' do
    expect { visit '/sidekiq' }.
      to raise_error(ApplicationController::RouteNotFound)
  end

  it 'does not expose the dashboard to ordinary users' do
    using_session(login(FactoryBot.create(:user))) do
      expect { visit '/sidekiq' }.
        to raise_error(ApplicationController::RouteNotFound)
    end
  end

  it 'serves the dashboard and queue views to administrators' do
    using_session(login(FactoryBot.create(:admin_user))) do
      visit '/sidekiq'
      expect(page.status_code).to eq(200)
      expect(page).to have_content('Sidekiq')
      visit '/sidekiq/queues'
      expect(page.status_code).to eq(200)
      expect(page).to have_content('Queues')
    end
  end
end
