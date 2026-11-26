require 'spec_helper'

# Where a page's notice goes (ApplicationHelper#band_notice): straight after
# its band on a band page, so it isn't split from the masthead; at the top of
# the content on a page with no band.
module BandNoticePage
  def notice_on_page
    Nokogiri::HTML(response.body)
  end

  def expect_after_band
    page = notice_on_page
    expect(page.at_css('.page-band + .band-flash #notice').text.strip).
      to eq('Saved.')
    expect(page.at_css('.band-flash')['data-controller']).to eq('flash-focus')
    expect(page.at_css('.band-flash')).to have_attribute('data-uncached')
    expect(page.css('#notice').size).to eq(1)
  end

  def expect_at_top
    page = notice_on_page
    expect(page.at_css('#content > #notice').text.strip).to eq('Saved.')
    expect(page.at_css('.band-flash')).to be_nil
    expect(page.css('#notice').size).to eq(1)
  end
end

RSpec.describe Topics::TopicsController, 'a band page', type: :controller do
  include BandNoticePage
  render_views

  it 'puts the notice straight after the band' do
    get :index, flash: { notice: 'Saved.' }
    expect_after_band
  end
end

RSpec.describe PublicBodyController, 'the authorities band',
               type: :controller do
  include BandNoticePage
  render_views

  it 'puts the notice straight after the band' do
    body = FactoryBot.create(:public_body)
    get :show, params: { url_name: body.url_name, view: 'all' },
               flash: { notice: 'Saved.' }
    expect_after_band
  end
end

RSpec.describe Users::PasswordsController, 'a plain page (page_band)',
               type: :controller do
  include BandNoticePage
  render_views

  before { request.env['devise.mapping'] = Devise.mappings[:user] }

  it 'puts the notice straight after the band' do
    get :new, flash: { notice: 'Saved.' }
    expect_after_band
  end
end

RSpec.describe HelpController, 'a page with no band', type: :controller do
  include BandNoticePage
  render_views

  it 'puts the notice at the top of the content' do
    get :about, flash: { notice: 'Saved.' }
    expect_at_top
  end
end

RSpec.describe Disclosures::DocumentsController, 'the documents list',
               type: :controller do
  include BandNoticePage
  render_views

  it 'puts the notice straight after the band' do
    get :index, flash: { notice: 'Saved.' }
    expect_after_band
  end
end
