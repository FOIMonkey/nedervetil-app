require 'spec_helper'

RSpec.describe 'admin/public_bodies/_summary' do
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }

  # The partial given only the authority, as a page that renders it may.
  def summary_of(body)
    assign :public_body, body
    render partial: 'admin/public_bodies/summary'
    Nokogiri::HTML.fragment(rendered)
  end

  def facts(page)
    page.css('.admin-facts > div').to_h do |row|
      [row.at_css('dt').text, row.at_css('dd').text.squish]
    end
  end

  def count_labels(page)
    page.css('.admin-counts a').map do |link|
      [link.at_css('b').text, link.at_css('span').text]
    end
  end

  def group(heading, title, tag)
    Category.create!(title: title, description: '', category_tag: tag,
                     parent_ids: [heading.id])
  end

  def heading(title)
    Category.create!(title: title, description: '',
                     parent_ids: [PublicBody.category_root.id])
  end

  def request_to(body, **attributes)
    FactoryBot.create(:info_request, public_body: body, user: owner,
                                     **attributes)
  end

  it 'says so when an authority has no tags, requests, documents or releases' do
    body = FactoryBot.create(:public_body)
    page = summary_of(body)
    expect(page.at_css('h1').text).to eq(body.name)
    expect(facts(page)).to include('Groups' => 'None', 'Map' => 'No area code')
    expect(facts(page)['FOI address']).
      to start_with("#{body.request_email} Requests can be sent")
    expect(facts(page).keys).not_to include('Other tags')
    expect(count_labels(page).map(&:first)).to eq(%w[0 0 0])
    expect(page.css('.admin-clear').map(&:text)).
      to eq(['None yet.', 'None yet.'])
    expect(page.at_css('#body-holds')).to be_nil
    expect(page.at_css('#body-who')).to be_nil
  end

  it 'puts its groups under their headings, says where each area code is on the map, and lists its other tags' do
    group(heading('Place'), 'South East', 'south_east')
    type = heading('Type')
    group(type, 'Police forces', 'police')
    group(type, 'District councils', 'district_council')
    body = FactoryBot.create(
      :public_body,
      tag_string: 'south_east police gss:E07000901 gss:E07000902 ' \
                  'gss:E10000901 misc'
    )
    page = summary_of(body)
    expect(page.css('.admin-chips__heading').map(&:text)).to eq(%w[Place Type])
    expect(page.css('a.admin-chip').map { |chip| [chip.text, chip['href']] }).
      to eq([['South East', '/groups/south_east'],
             ['Police forces', '/groups/police']])
    expect(page.css('.admin-map-code').map { |code| code.text.squish }).
      to eq(['E07000901 On the map',
             'E07000902 Not on the map: (Brackwater, ended)',
             'E10000901 Listed, not drawn: it has no district area of its ' \
             'own'])
    expect(facts(page)['Other tags']).to include('misc')
    expect(facts(page)['Other tags']).not_to include('south_east', 'gss')
  end

  it 'counts no requests for a new authority' do
    body = FactoryBot.create(:public_body)
    expect(count_labels(summary_of(body)).first).to eq(%w[0 requests])
  end

  it 'counts its one request' do
    body = FactoryBot.create(:public_body)
    request_to(body)
    expect(count_labels(summary_of(body)).first).to eq(%w[1 request])
  end

  it 'counts its requests, the hidden with the rest' do
    body = FactoryBot.create(:public_body)
    request_to(body)
    request_to(body, prominence: 'hidden')
    expect(count_labels(summary_of(body)).first).to eq(%w[2 requests])
  end

  it 'lists the five newest published documents and links to all of them' do
    body = FactoryBot.create(:public_body)
    request = request_to(body)
    documents = Array.new(6) do |index|
      publish(delivered_document(request, "runs#{index}.txt", 'text/plain',
                                 "Gritting by ward\nNorth: 1#{index} runs\n",
                                 by: owner, ready: false),
              by: admin)
    end
    page = summary_of(body)
    section = page.at_css('#body-documents')
    expect(count_labels(page)[1]).to eq(['6', 'documents published'])
    expect(section.at_css('.admin-block__count').text).to eq('6')
    expect(section.at_css('a.admin-block__more').text).to eq('All 6')
    expect(section.at_css('a.admin-block__more')['href']).
      to eq("/documents?body=#{body.url_name}")
    expect(section.css('a.admin-rows__title').map { |link| link['href'] }).
      to eq(documents.last(5).reverse.map { |document|
        "/documents/#{document.public_id}/manage"
      })
    expect(section.at_css('.admin-rows__meta').text).to include('public since')
  end

  it 'lists its external releases, newest first, with what each can be switched to' do
    body = FactoryBot.create(:public_body)
    older = AuthorityGroups::ExternalRelease.create!(
      public_body: body, title: 'Older release',
      url: 'https://log.example.invalid/older',
      released_on: Date.new(2026, 9, 1),
      hidden_at: Time.zone.now, pinned_at: Time.zone.now
    )
    newer = AuthorityGroups::ExternalRelease.create!(
      public_body: body, title: 'Newer release',
      url: 'https://log.example.invalid/newer',
      released_on: Date.new(2026, 9, 2)
    )
    page = summary_of(body)
    section = page.at_css('#body-releases')
    expect(count_labels(page)[2]).to eq(['2', 'external releases'])
    expect(section.at_css('a.admin-block__more').text).to eq('All 2')
    rows = section.css('.admin-releases tr')
    expect(rows.map { |row| row.at_css('td a').text }).
      to eq(['Newer release', 'Older release'])
    expect(rows.map { |row| row.at_css('td').text }).
      to eq(['2 Sep 2026', '1 Sep 2026'])
    expect(rows[0].css('form').map { |form| form['action'] }).
      to eq(["/admin/external_releases/#{newer.id}/hide",
             "/admin/external_releases/#{newer.id}/pin"])
    expect(rows[1].css('.label').map(&:text)).to eq(%w[Hidden Pinned])
    expect(rows[1].css('form').map { |form| form['action'] }).
      to eq(["/admin/external_releases/#{older.id}/unhide",
             "/admin/external_releases/#{older.id}/unpin"])
  end

  it 'ticks what its kind of authority holds, less what an admin unticked' do
    body = FactoryBot.create(
      :public_body,
      name: 'Ashdown District Council',
      tag_string: 'local_council district_council england ' \
                  'holds_not:food_hygiene'
    )
    boxes = summary_of(body).css('#body-holds input[type=checkbox]')
    checked = boxes.to_h { |box| [box['value'], box.key?('checked')] }
    expect(checked).to include('bins_street' => true, 'food_hygiene' => false)
    expect(checked.keys.uniq).to eq(checked.keys)
  end

  describe 'for an authority the topic files name' do
    let(:body) do
      FactoryBot.create(:public_body, name: 'Caledon Police',
                                      tag_string: 'police scotland')
    end

    it 'offers the words from the topic files until an admin writes a line' do
      field = summary_of(body).at_css('#body-who input[name=line]')
      expect(field['placeholder']).to start_with('Crime, stop and search')
      expect(field['value']).to be_nil
    end

    it 'shows the line an admin saved' do
      AuthorityGroups::WhoLine.save_for(body, 'Crime across Scotland')
      field = summary_of(body).at_css('#body-who input[name=line]')
      expect(field['value']).to eq('Crime across Scotland')
    end
  end
end
