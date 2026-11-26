require 'spec_helper'

RSpec.describe 'general/_opengraph_tags' do
  def render_view
    render partial: 'general/opengraph_tags'
  end

  # The inbox is for every account, so it is named and shown like the rest of
  # the site.
  it 'uses the site name and logo in the inbox too' do
    assign(:in_pro_area, true)
    allow(AlaveteliConfiguration).to receive(:site_name).and_return('Example')
    render_view
    expect(rendered).
      to include('<meta property="og:site_name" content="Example" />').
      and match(%r{content="http://test\.host/assets/logo-opengraph[-.]})
  end
end
