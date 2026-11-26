require 'spec_helper'

RSpec.describe 'Authority groups' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include DisclosuresCatalogueFixtures
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:root) { PublicBody.category_root }
  let(:place_heading) do
    Category.create!(title: 'Place', description: '', parent_ids: [root.id])
  end
  let!(:south_east) { group(place_heading, 'South East', 'south_east') }
  let!(:member) do
    FactoryBot.create(:public_body,
                      name: 'Westmoor Borough Council',
                      tag_string: 'south_east district')
  end
  let!(:outsider) do
    FactoryBot.create(:public_body,
                      name: 'Northern Council',
                      tag_string: 'north_east')
  end
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, public_body: member)
  end

  def group(heading, title, tag)
    Category.create!(title: title, description: '', category_tag: tag,
                     parent_ids: [heading.id])
  end

  def release(body, title, released_on, **attributes)
    AuthorityGroups::ExternalRelease.create!(
      public_body: body, title: title, released_on: released_on,
      url: "https://log.example.invalid/#{title.parameterize}", **attributes
    )
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def document(publish:)
    message = AttachmentFixtures.deliver(
      info_request,
      [['response.pdf', 'application/pdf',
        AttachmentFixtures.pdf(
          pages: [AttachmentFixtures.letter_page(secret: 'Grit')]
        )]]
    )
    attachment = message.get_attachments_for_display.
      find { |a| a.filename == 'response.pdf' }
    made = Disclosures::Creation.new(user: owner, attachment: attachment,
                                     kind: 'released_records').create!
    return made.reload unless publish

    publish(made, by: admin)
    made.reload
  end

  describe 'browsing' do
    let(:type_heading) do
      Category.create!(title: 'Type', description: '', parent_ids: [root.id])
    end
    let(:sector_heading) do
      Category.create!(title: 'Sector', description: '', parent_ids: [root.id])
    end

    it 'lists places, types and themes with no counts, leaving out empty and hidden groups' do
      group(type_heading, 'District councils', 'district')
      group(sector_heading, 'Transport', 'transport')
      group(place_heading, 'Wales', 'wales')
      AuthorityGroups::Setting.
        hide!(group(place_heading, 'North East', 'north_east'))

      get '/groups'
      expect(response).to have_http_status(:ok)
      expect(page.css('.groups-index__section h2').map(&:text)).
        to eq(%w[Places Types])
      expect(page.css('.groups-index__list li').map { |li| li.text.squish }).
        to eq(['South East', 'District councils'])
    end

    it 'shows a few groups per heading, then pages through all of them in the admins’ order' do
      stub_const('AuthorityGroups::GroupsController::INDEX_SIZE', 2)
      stub_const('AuthorityGroups::GroupsController::BROWSE_SIZE', 2)
      %w[c b].each do |letter|
        group(place_heading, "Place #{letter}", "place_#{letter}")
        FactoryBot.create(:public_body, tag_string: "place_#{letter}")
      end

      get '/groups'
      expect(page.css('.groups-index__list a').map(&:text)).
        to eq(['South East', 'Place c'])
      expect(page.at_css('a[href="/groups?by=place"]').text).
        to eq('View all places')

      get '/groups', params: { by: 'place', page: 2 }
      expect(page.css('.groups-index__list a').map(&:text)).to eq(['Place b'])
      expect(page.at_css('.groups-pager a[rel="prev"]')['href']).
        to eq('/groups?by=place&page=1')

      get '/groups', params: { by: 'nowhere' }
      expect(response).to have_http_status(:not_found)
    end

    it 'falls back to the A to Z list before any group has members' do
      member.update!(tag_string: '')
      get '/groups'
      expect(response).to redirect_to('/body/list/all')
    end
  end

  describe 'a group page' do
    it 'shows published documents only and visible releases, pinned first, with no counts, never cached' do
      published = document(publish: true)
      draft = document(publish: false)
      release(member, 'Older release', Date.new(2026, 6, 1))
      release(member, 'Newer release', Date.new(2026, 7, 1))
      release(member, 'Pinned release', Date.new(2025, 1, 1),
              pinned_at: Time.current)
      release(member, 'Hidden release', Date.new(2026, 7, 2),
              hidden_at: Time.current)
      release(outsider, 'Outsider release', Date.new(2026, 7, 3))

      get '/groups/south_east'
      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to eq('private, no-store')
      expect(page.css('section[aria-labelledby="group-elsewhere"] ' \
                      '.group-page__list a').map(&:text)).
        to eq(['Pinned release', 'Newer release', 'Older release'])
      expect(page.css('.body-tabs a').map(&:text)).
        to eq(%w[Overview Authorities Documents])
      expect(page.at_css('.page-band__figures')).to be_nil
      expect(page.text).to include(published.title)
      expect(response.body).not_to include("/documents/#{draft.public_id}",
                                           'Northern Council', 'Hidden release')
      expect(page.at_css('.group-page__external')['rel']).
        to eq('nofollow noopener')

      get '/groups/south_east/authorities'
      expect(page.css('.members__list a').map(&:text)).
        to eq(['Westmoor Borough Council'])
    end

    it 'leaves out a section of nothing, and says View all only when there is more' do
      get '/groups/south_east'
      expect(page.css('.body-tabs a').map(&:text)).
        to eq(%w[Overview Authorities])
      expect(page.at_css('#group-here, #group-elsewhere, #body-decisions, ' \
                         '.spotlights, #group-compare')).to be_nil

      5.times do |index|
        release(member, "Release #{index}", Date.new(2026, 7, index + 1))
      end
      get '/groups/south_east'
      expect(page.at_css('.body-more')).to be_nil
      release(member, 'Release 5', Date.new(2026, 7, 6))
      get '/groups/south_east'
      expect(page.css('section[aria-labelledby="group-elsewhere"] ' \
                      '.group-page__list li').size).to eq(5)
      expect(page.at_css('.body-more a').
               then { |link| [link.text, link['href']] }).
        to eq(['View all releases', '/groups/south_east/releases'])
      expect(page.at_css('.body-tabs a[href="/groups/south_east/releases"]').
               text).to eq('Documents')
    end

    it 'shows the category’s intro' do
      south_east.update!(body: 'Councils in the South East.')
      get '/groups/south_east'
      expect(page.at_css('.group-page__intro').text).
        to include('Councils in the South East.')
    end

    it 'pages through all releases, and lists every member by kind on one page unless the group is big' do
      stub_const('AuthorityGroups::GroupsController::SECTION_SIZES',
                 { 'documents' => 2, 'releases' => 2, 'authorities' => 2 })
      group(Category.create!(title: 'Type', description: '',
                             parent_ids: [root.id]),
            'District councils', 'district')
      3.times do |index|
        release(member, "Release #{index}", Date.new(2026, 7, index + 1))
      end
      %w[Aston Burford].each do |name|
        FactoryBot.create(:public_body, name: "#{name} Council",
                                        tag_string: 'south_east')
      end

      get '/groups/south_east/releases', params: { page: 2 }
      expect(page.css('.group-page__list a').map(&:text)).to eq(['Release 0'])
      expect(page.at_css('a[rel="prev"]')['href']).
        to eq('/groups/south_east/releases?page=1')

      get '/groups/south_east/authorities'
      expect(page.css('.members__kind h2').map(&:text)).
        to eq(['District councils', 'Others'])
      expect(page.css('.members__list a').map(&:text)).
        to eq(['Westmoor Borough Council', 'Aston Council', 'Burford Council'])
      expect(page.at_css('.body-tabs a[aria-current="page"]').text).
        to eq('Authorities')

      stub_const('AuthorityGroups::GroupsController::KINDS_MAX', 2)
      get '/groups/south_east/authorities'
      expect(page.css('.members__kind h2').map(&:text)).to eq(['Authorities'])
      expect(page.css('.members__list a').map(&:text)).
        to eq(['Aston Council', 'Burford Council'])
      expect(page.at_css('.groups-pager a[rel="next"]')['href']).
        to eq('/groups/south_east/authorities?page=2')
    end

    it 'lists documents from their approved details, in the same statements for any number of authorities' do
      base = expand_catalogue(document(publish: true), 24)
      spread = ->(count) do
        bodies = Array.new(count) do |index|
          FactoryBot.create(:public_body,
                            name: "Synthetic member #{count}-#{index}",
                            tag_string: 'south_east')
        end
        Disclosures::Document.where('id > ?', base).order(:id).
          each_with_index do |record, index|
            record.update_columns(public_body_id: bodies[index % count].id)
          end
      end
      statements = ->(path) do
        get path
        queries = []
        listener = ->(*, payload) do
          unless payload[:cached] ||
                 %w[SCHEMA TRANSACTION].include?(payload[:name])
            queries << payload[:sql]
          end
        end
        ActiveSupport::Notifications.
          subscribed(listener, 'sql.active_record') { get path }
        expect(response).to have_http_status(:ok)
        expect(queries.grep(/\ASELECT "info_requests"\.\*/)).to be_empty
        queries.size
      end
      spread.call(6)
      few = %w[/groups/south_east /groups/south_east/documents].
        map(&statements)
      spread.call(24)
      expect(%w[/groups/south_east /groups/south_east/documents].
               map(&statements)).to eq(few)
      expect(page.css('.group-page__list li').size).to eq(25)
      expect(page.css('.group-page__meta').
               map { |meta| meta.text.split(' · ').first }).
        to include('Synthetic member 24-0')
    end

    it 'is a 404 when hidden, except to admins' do
      AuthorityGroups::Setting.hide!(south_east)
      get '/groups/south_east'
      expect(response).to have_http_status(:not_found)

      sign_in(admin)
      get '/groups/south_east'
      expect(response).to have_http_status(:ok)
      expect(page.at_css('.group-page__hidden').text).
        to eq('Hidden from visitors.')
    end

    it 'is a 404 for a suspended admin' do
      AuthorityGroups::Setting.hide!(south_east)
      sign_in(admin)
      admin.update!(ban_text: 'Suspended')
      get '/groups/south_east'
      expect(response).to have_http_status(:not_found)
    end

    it 'is a 404 past the last page anyone needs' do
      get '/groups/south_east/releases',
          params: { page: AuthorityGroups::GroupsController::MAX_PAGE }
      expect(response).to have_http_status(:ok)
      get '/groups/south_east/releases',
          params: { page: AuthorityGroups::GroupsController::MAX_PAGE + 1 }
      expect(response).to have_http_status(:not_found)
    end

    it 'is a 404 for an unknown tag, a tag outside the headings, or a reserved tag' do
      Category.create!(title: 'Loose', description: '', category_tag: 'loose',
                       parent_ids: [root.id])
      %w[/groups/nowhere /groups/loose /groups/all].each do |path|
        get path
        expect(response).to have_http_status(:not_found), path
      end
    end

    it 'filters documents by place or type, never as a sector' do
      document(publish: true)
      expect(Disclosures::Search.new({}).facet(:sector)).to be_empty
      expect(Disclosures::Search.new({}).facet(:group)).
        to eq([['south_east', 'South East', 1]])
      get '/documents'
      facet = page.css('.documents__filters .documents-facet').
        find { |fieldset| fieldset.at_css('legend').text == 'Place or type' }
      expect(facet.css('label').map { |label| label.text.squish }).
        to eq(['All', 'South East'])
      expect(Disclosures::Search.new(group: 'south_east').total).to eq(1)
      expect(Disclosures::Search.new(group: 'north_east').filters).to be_empty
    end
  end

  describe 'admin pages' do
    let!(:existing) { release(member, 'Parking permits', Date.new(2026, 7, 1)) }

    it 'are for admins only' do
      allow(AlaveteliConfiguration).to receive(:skip_admin_auth).
        and_return(false)
      [['get', '/admin/authority_groups'], ['get', '/admin/external_releases'],
       ['post', "/admin/external_releases/#{existing.id}/hide"],
       ['get', '/admin/external_release_imports/new'],
       ['post', "/admin/bodies/#{member.id}/who_line?line=Taken"]].
        each do |verb, path|
        [nil, owner].each do |user|
          user ? sign_in(user) : reset!
          public_send(verb, path)
          expect(response).
            not_to have_http_status(:ok),
                   "#{verb} #{path} as #{user&.name || 'visitor'}"
        end
      end
      expect(existing.reload).not_to be_hidden
      expect(AuthorityGroups::WhoLine.count).to eq(0)
    end

    it 'hide and show a group' do
      sign_in(admin)
      get '/admin/authority_groups'
      expect(page.css('table tbody tr td:first-child').map(&:text)).
        to eq(['South East'])

      post "/admin/authority_groups/#{south_east.id}/hide"
      expect(AuthorityGroups::Group.find('south_east')).to be_nil
      post "/admin/authority_groups/#{south_east.id}/show"
      expect(AuthorityGroups::Group.find('south_east').title).
        to eq('South East')

      other = Category.create!(title: 'Not a group', description: '',
                               category_tag: 'not_a_group',
                               parent_ids: [root.id])
      post "/admin/authority_groups/#{other.id}/hide"
      expect(response).to have_http_status(:not_found)
      expect(AuthorityGroups::Setting.where(category: other)).to be_empty
    end

    it 'add, edit, hide, pin and delete releases' do
      sign_in(admin)
      post '/admin/external_releases', params: {
        body: member.url_name,
        external_release: { title: 'Bin collections',
                            url: 'HTTPS://Log.Example.invalid/bins#top',
                            released_on: '2026-07-04' }
      }
      added = AuthorityGroups::ExternalRelease.
        find_by!(title: 'Bin collections')
      expect(added.url).to eq('https://log.example.invalid/bins')

      post '/admin/external_releases', params: {
        body: member.url_name,
        external_release: { title: 'Again',
                            url: 'https://log.example.invalid/bins',
                            released_on: '2026-07-04' }
      }
      expect(response).to have_http_status(422)
      expect(page.text).to include('Url is already listed for this authority')

      post '/admin/external_releases', params: {
        body: member.url_name,
        external_release: { title: 'Script', url: 'javascript:alert(1)',
                            released_on: '2026-07-04' }
      }
      expect(response).to have_http_status(422)

      patch "/admin/external_releases/#{existing.id}", params: {
        body: member.url_name,
        external_release: { title: 'Parking permits issued',
                            url: existing.url, released_on: '2026-07-01' }
      }
      expect(existing.reload.title).to eq('Parking permits issued')
      expect(existing.edited_at).to be_present

      post "/admin/external_releases/#{existing.id}/hide"
      post "/admin/external_releases/#{added.id}/pin"
      expect([existing.reload.hidden?, added.reload.pinned?]).
        to eq([true, true])

      get '/admin/external_releases', params: { state: 'hidden' }
      expect(page.css('tbody tr').size).to eq(1)

      delete "/admin/external_releases/#{added.id}"
      expect(AuthorityGroups::ExternalRelease.exists?(added.id)).to be(false)
    end

    it 'link from the admin navigation' do
      sign_in(admin)
      get '/admin/authority_groups'
      expect(page.css('#admin-bar a').map(&:text)).
        to include('Groups', 'External releases')
    end
  end

  describe 'maps' do
    let(:ashcombe) do
      FactoryBot.create(:public_body,
                        name: 'Ashcombe District Council',
                        tag_string: 'south_east gss:E07000901')
    end
    let(:brackwater) do
      FactoryBot.create(:public_body,
                        name: 'Brackwater Borough Council',
                        tag_string: 'gss:E07000902')
    end
    let(:westshire) do
      FactoryBot.create(:public_body,
                        name: 'Westshire County Council',
                        tag_string: 'south_east gss:E10000901')
    end

    def map_links
      page.css('svg.group-map a').map do |link|
        [link['href'], link.at_css('title').text]
      end
    end

    it 'link a group’s members on its Authorities tab, not its Overview, for pointers only; counties are only listed' do
      ashcombe
      westshire
      get '/groups/south_east'
      expect(page.at_css('svg.group-map')).to be_nil

      get '/groups/south_east/authorities'
      expect(map_links).
        to eq([["/body/#{ashcombe.url_name}", 'Ashcombe District Council']])
      expect(page.at_css('svg.group-map')['aria-hidden']).to eq('true')
      expect(page.css('svg.group-map path').size).to be > 1
      expect(page.css('.members__list a').map(&:text)).
        to include('Westshire County Council')
      expect(page.text).to include('Contains OS data © Crown copyright')
    end

    it 'show an authority’s own area on its page, an abolished council’s too, and nothing without one' do
      get "/body/#{ashcombe.url_name}"
      expect(map_links).
        to eq([["/body/#{ashcombe.url_name}", 'Ashcombe District Council']])

      get "/body/#{brackwater.url_name}"
      expect(map_links.map(&:last)).to eq(['Brackwater Borough Council'])

      get "/body/#{westshire.url_name}"
      expect(page.at_css('svg.group-map')).to be_nil
    end

    it 'list for admins the authorities whose code is no longer a current area, unless defunct' do
      brackwater
      westshire
      FactoryBot.create(:public_body, name: 'Coldfell Borough Council',
                                      tag_string: 'gss:E07000903 defunct')
      FactoryBot.create(:public_body, name: 'Typo Council',
                                      tag_string: 'gss:E07999999')
      FactoryBot.create(:public_body, name: 'Short Council',
                                      tag_string: 'gss:E0700022')
      sign_in(admin)
      get '/admin/authority_groups'
      expect(page.css('.alert li').map { |li| li.text.squish }).
        to eq(['Brackwater Borough Council: E07000902 (Brackwater, ended)',
               'Short Council: E0700022 (unknown code)',
               'Typo Council: E07999999 (unknown code)'])
    end

    it 'draw only the current area when an old code is left beside it, and tell admins to remove it' do
      dunmere = FactoryBot.create(:public_body,
                                  name: 'Dunmere City Council',
                                  tag_string: 'gss:E08000901 gss:E08000902')
      get "/body/#{dunmere.url_name}"
      expect(page.css('svg.group-map .is-member').size).to eq(1)

      sign_in(admin)
      get '/admin/authority_groups'
      alert = page.at_css('.alert')
      expect(alert.text).not_to include('not on the map')
      expect(alert.css('li').map { |li| li.text.squish }).
        to eq(['Dunmere City Council: E08000901 (Dunmere, ended)'])
    end

    it 'link a shared code to one authority, always the same one, and list it for admins' do
      ashcombe
      copy = FactoryBot.create(:public_body,
                               name: 'Ashcombe Copy Council',
                               tag_string: 'south_east gss:E07000901')
      2.times do
        get '/groups/south_east/authorities'
        expect(map_links).
          to eq([["/body/#{ashcombe.url_name}", 'Ashcombe District Council']])
      end

      sign_in(admin)
      get '/admin/authority_groups'
      expect(page.css('.alert li').map { |li| li.text.squish }).
        to eq(["E07000901 (Ashcombe): Ashcombe District Council, #{copy.name}"])
    end
  end

  it 'loads all its classes' do
    expect { Rails.autoloaders.main.eager_load_namespace(AuthorityGroups) }.
      not_to raise_error
    expect(AuthorityGroups::ExternalRelease.table_name).
      to eq('external_releases')
  end
end
