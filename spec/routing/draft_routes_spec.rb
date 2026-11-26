require 'spec_helper'

# A draft is saved only by the request journey, as a letter is written
# (AlaveteliPro::InfoRequestsController), which keeps what was typed even
# when it isn't valid yet. The draft controller only deletes.
RSpec.describe 'Draft routes', type: :routing do
  it 'routes deleting a draft' do
    expect(delete: '/pro/draft_info_requests/1').to route_to(
      controller: 'alaveteli_pro/draft_info_requests', action: 'destroy',
      id: '1'
    )
  end

  # A path nothing matches goes to the not-found page, or has no route.
  it 'has no route that saves a draft outside the request journey' do
    expect(post: '/pro/draft_info_requests').to route_to(
      controller: 'general', action: 'not_found',
      path: 'pro/draft_info_requests'
    )
    expect(put: '/pro/draft_info_requests/1').not_to be_routable
    expect(patch: '/pro/draft_info_requests/1').not_to be_routable
  end
end
