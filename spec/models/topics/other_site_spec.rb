require 'spec_helper'

RSpec.describe Topics::OtherSite do
  before do
    allow(AlaveteliConfiguration).to receive(:other_foi_site_name).
      and_return('Example FOI site')
  end

  ['javascript:alert(1)', 'data:text/html,test', '//example.test',
   'https:', 'not a URL'].each do |url|
    it "ignores an invalid site URL #{url.inspect}" do
      allow(AlaveteliConfiguration).to receive(:other_foi_site_url).
        and_return(url)
      expect(described_class.url).to be_nil
      expect(described_class.url('roads')).to be_nil
    end
  end

  it 'preserves the query of a web URL' do
    allow(AlaveteliConfiguration).to receive(:other_foi_site_url).
      and_return('https://example.test/search?lang=cy')
    expect(described_class.url('Roads & repairs')).
      to eq('https://example.test/search?lang=cy&query=Roads+%26+repairs')
  end

  it 'links to past requests on the other site' do
    allow(AlaveteliConfiguration).to receive(:other_foi_site_url).
      and_return('https://example.test/select_authority')
    expect(described_class.search_url('road defect')).
      to eq('https://example.test/search/road%20defect/requests')
  end

  it 'has no past requests without a site' do
    allow(AlaveteliConfiguration).to receive(:other_foi_site_url).and_return('')
    expect(described_class.search_url('roads')).to be_nil
  end
end
