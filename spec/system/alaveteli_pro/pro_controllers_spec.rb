require 'spec_helper'
require 'integration/alaveteli_dsl'

# Pro controllers whose pages this fork doesn't serve (the single-request
# form and sidebar partials aren't rendered) can't be visited, so their
# markup is put into the Pro dashboard, where Stimulus connects it as it
# would on its own page.
RSpec.describe 'Pro Stimulus controllers', js: true do
  let(:pro_user) { FactoryBot.create(:pro_user) }

  before { with_feature_enabled(:alaveteli_pro) }

  def on_dashboard
    using_pro_session(login(pro_user)) do
      visit alaveteli_pro_dashboard_path
      yield
    end
  end

  def inject(html)
    page.execute_script(
      "document.getElementById('content')." \
      "insertAdjacentHTML('beforeend', arguments[0])",
      html
    )
  end

  describe 'auto-submit' do
    it 'sorts the requests list as soon as a sort is chosen' do
      FactoryBot.create(:info_request, user: pro_user)
      using_pro_session(login(pro_user)) do
        visit alaveteli_pro_info_requests_path(
          'alaveteli_pro_request_filter[filter]' => 'awaiting-response'
        )
        select 'Title (A-Z)', from: 'Sort by'
        expect(page).
          to have_current_path(/order%5D=title_asc|order\]=title_asc/)
        expect(page).to have_select('Sort by', selected: 'Title (A-Z)')
      end
    end
  end

  describe 'checkbox-gate' do
    it 'keeps a batch from sending until "send anyway" is ticked' do
      on_dashboard do
        inject(<<~HTML)
          <form data-controller="checkbox-gate" action="/fake-send">
            <label><input type="checkbox" id="anyway" data-checkbox-gate-target="checkbox"
                          data-action="checkbox-gate#sync"> Send this batch anyway?</label>
            <input type="submit" value="Send 3 requests" data-checkbox-gate-target="submit">
          </form>
        HTML
        expect(page).to have_button('Send 3 requests', disabled: true)
        check 'anyway'
        expect(page).to have_button('Send 3 requests', disabled: false)
        uncheck 'anyway'
        expect(page).to have_button('Send 3 requests', disabled: true)
      end
    end
  end
end
