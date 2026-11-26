require 'spec_helper'

RSpec.describe 'Making a request', feature: :alaveteli_pro do
  include_context 'with incoming attention off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:authority) {
    FactoryBot.create(:public_body,
                      name: 'Northmoor County Council',
                      tag_string: 'county_council')
  }

  def page
    Nokogiri::HTML(response.body)
  end

  describe RequestLetter do
    it 'joins the typed middle into core’s letter and splits it back out' do
      body = described_class.join("Please provide the gritting routes.\r\n",
                                  'Northmoor County Council',
                                  'Rowan Requester')
      expect(body).
        to eq("Dear Northmoor County Council,\n\nPlease provide the gritting " \
              "routes.\n\nYours faithfully,\n\nRowan Requester")
      expect(described_class.split(body,
                                   'Northmoor County Council',
                                   'Rowan Requester')).
        to eq('Please provide the gritting routes.')
      expect(described_class.split("Dear Ms Officer,\n\nPlease.\n\nYours " \
                                   "faithfully,\n\nRowan Requester",
                                   'Northmoor County Council',
                                   'Rowan Requester')).to be_nil
    end

    it 'writes the authority’s name as text, with its ampersands and apostrophes' do
      body = described_class.join('Please send the policy.',
                                  "Children's Services & Schools",
                                  'Rowan Requester')
      expect(body.lines.first).to eq("Dear Children's Services & Schools,\n")
      expect(described_class.split(body,
                                   "Children's Services & Schools",
                                   'Rowan Requester')).
        to eq('Please send the policy.')
    end

    it 'still splits a letter saved with the name HTML-escaped' do
      saved = "Dear Children&#39;s Services &amp; Schools,\n\nPlease send " \
              "the " \
              "policy.\n\nYours faithfully,\n\nRowan Requester"
      expect(described_class.split(saved,
                                   "Children's Services & Schools",
                                   'Rowan Requester')).
        to eq('Please send the policy.')
    end
  end

  describe Deadlines::FollowupLetter do
    it 'writes the authority’s name into a follow-up as text' do
      body = FactoryBot.create(:public_body,
                               name: "Children's Services & Schools")
      request = FactoryBot.create(:info_request, public_body: body)
      letter = described_class.join('Any news?',
                                    request,
                                    nil,
                                    false,
                                    'Rowan Requester')
      expect(letter.lines.first).to eq("Dear Children's Services & Schools,\n")
      expect(letter).
        to end_with("Any news?\n\nYours faithfully,\n\nRowan Requester")
    end
  end

  describe Topics::Holds do
    it 'says what that kind of body usually holds, from the topic files' do
      expect(described_class.line(authority)).
        to start_with('County council · England · usually holds ')
      expect(described_class.line(authority)).
        to include('local roads, potholes and street lights')
      expect(described_class.line(FactoryBot.create(:public_body))).to be_nil
    end

    it 'shows two holders, any naming the body first, and keeps names as written' do
      expect(described_class.summary(authority).count(';')).to eq(1)
      expect(described_class.summary(authority, limit: 20)).
        to include('Household Support Grant', 'local roads')
      agency = FactoryBot.create(:public_body,
                                 name: 'Revenue and Benefits Agency',
                                 tag_string: 'county_council')
      expect(described_class.summary(agency)).
        to start_with('income tax, Family Allowance and tax refunds; ')
    end
  end

  it 'finds an authority by name on the Who step, saying what it holds, with no batch link' do
    authority
    sign_in(owner)
    get new_alaveteli_pro_info_request_path(question: 'Gritting routes',
                                            go: 1,
                                            query: 'Northmoor')
    expect(response).to have_http_status(:ok)
    result = page.at_css('.authority-results li')
    expect(result.at_css('a')['href']).
      to eq(new_alaveteli_pro_info_request_path(question: 'Gritting routes',
                                                subject: 'Gritting routes',
                                                public_body: authority.url_name,
                                                step: 'subject'))
    expect(result.at_css('.authority-results__meta').text).
      to include('usually holds')
    expect(page.at_css('#content h1').text).to eq('Who holds it?')
    expect(page.at_css('[aria-current="step"]').text).to include('Who')
    expect(response.body).not_to include('batch request')
  end

  it 'edits an older letter whole' do
    sign_in(owner)
    draft = FactoryBot.create(
      :draft_info_request,
      user: owner, title: 'Gritting routes 2025', public_body: authority,
      body: "Dear Ms Officer,\n\nPlease provide the routes.\n\nYours " \
            "faithfully,\n\nRowan Requester"
    )
    get new_alaveteli_pro_info_request_path(draft_id: draft.id)
    expect(page.at_css('textarea[name="outgoing_message[body]"]').text).
      to include('Dear Ms Officer')
    expect(page.at_css('.request-sheet__fixed')).to be_nil
  end

  it 'offers Ask on the authority page to a signed-in user only, while sign-ups are closed' do
    allow(AlaveteliConfiguration).
      to receive(:read_only_features).and_return(['signups'])
    ask = 'a.page-band__button:not(.page-band__button--ghost)'
    get "/body/#{authority.url_name}"
    expect(page.at_css(ask)).to be_nil
    sign_in(owner)
    get "/body/#{authority.url_name}"
    expect(page.at_css(ask).then { [_1.text, _1['href']] }).
      to eq(["Make request to #{authority.name}",
             new_alaveteli_pro_info_request_path(
               public_body: authority.url_name
             )])
  end

  # Every signed-in account writes in the inbox form (#93), whatever the
  # flag or its role.
  it 'sends an account to the inbox form while Pro is switched off' do
    allow(AlaveteliFeatures.backend).
      to receive(:enabled?).with(:alaveteli_pro).and_return(false)
    sign_in(owner)
    get "/body/#{authority.url_name}"
    expect(
      page.at_css('a.page-band__button:not(.page-band__button--ghost)')['href']
    ).to eq(
      new_alaveteli_pro_info_request_path(public_body: authority.url_name)
    )
  end

  it 'says on the authority page what kind of body it is, where, what it usually holds and what it released elsewhere' do
    AuthorityGroups::ExternalRelease.create!(
      public_body: authority,
      title: 'Synthetic own-site release',
      url: 'https://example.invalid/own',
      released_on: Date.new(2026, 9, 1)
    )
    get "/body/#{authority.url_name}"
    expect(page.at_css('.page-band__summary').text).
      to eq('County council in England')
    expect(page.at_css('#body-releases').parent.text).
      to include('Synthetic own-site release')
    holds = page.css('.body-holds li').to_h {
      [_1.at_css('.body-holds__what').text, _1.at_css('a')['href']]
    }
    expect(holds).
      to include('Local roads, potholes and street lights' => '/topics/streets')
  end
end
