require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe RequestController do
  describe 'when the site is in read only mode' do
    before do
      allow(AlaveteliConfiguration).to receive(:read_only).
        and_return("Down for maintenance")
    end

    it 'shows a flash alert to users' do
      expected_message = "Alaveteli is currently in maintenance. " \
                         "Down for maintenance"
      visit new_request_path
      expect(page).to have_content(expected_message)
    end
  end

  describe 'when requests feature is in read only mode' do
    before do
      allow(AlaveteliConfiguration).to receive(:read_only_features).
        and_return(["requests"])
    end

    it 'shows a flash alert to users' do
      expected_message = "Alaveteli is currently in maintenance."
      visit new_request_path
      expect(page).to have_content(expected_message)
    end
  end

  it "should redirect from a numeric URL to pretty one" do
    using_session(login(:bob_smith_user)) do
      visit show_request_path(info_requests(:naughty_chicken_request).id)
      expect(page).to have_current_path(
        show_request_path(
          info_requests(:naughty_chicken_request).url_title
        ), ignore_query: true
      )
    end
  end
end
