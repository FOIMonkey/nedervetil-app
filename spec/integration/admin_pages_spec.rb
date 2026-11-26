require 'spec_helper'

RSpec.describe 'Admin pages' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:body) do
    FactoryBot.create(:public_body, name: 'Synthetic County Council')
  end
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner,
                                     public_body: body,
                                     title: 'Gritting routes 2024')
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def make_document(name = 'runs.txt', text = "Gritting by ward\nNorth: 12 runs\n")
    delivered_document(info_request, name, 'text/plain', text,
                       by: owner, ready: false)
  end

  describe 'the admin bar' do
    it 'splits queues and records, links jump, and opens tools in details' do
      make_document
      sign_in(admin)
      get '/admin'
      bar = page.at_css('#admin-bar')
      expect(bar.css('.admin-bar__group--queues > a').map { _1.text.squish }).
        to eq(%w[Today Documents])
      expect(bar.css('.admin-bar__group--records > a').map { _1.text.squish }).
        to eq(%w[Requests Authorities Users Topics])
      expect(bar.at_css('a[href="/documents/review"]').text.squish).
        to start_with('Documents')
      expect(bar.at_css('a[aria-current="page"]')['href']).to eq('/admin')
      expect(bar.at_css('a.admin-bar__jump')['href']).to eq('/admin/jump')
      details = bar.at_css('details.admin-bar__more')
      expect(details).to be_present
      expect(details.at_css('summary.admin-bar__toggle').text.squish).
        to eq('Tools')
      expect(details.at_css('#admin-more')).to be_present
      expect(bar.css('a').map { _1['href'] }).to all(be_present)
    end

    it 'keeps every tool core’s admin bar links to' do
      core = File.read(Rails.root.join('spec/fixtures/files/upstream_views/' \
                                       'admin_general/_admin_navbar.html.erb'))
      ours = Rails.root.join('app/views/admin/general/' \
                             '_admin_navbar.html.erb').read
      # Tools removed from the fork on purpose (see doc/FORK.md).
      removed = %w[admin_blog_posts_path admin_projects_path
                   admin_citations_path admin_tracks_path
                   admin_comments_path user_path admin_users_sessions_path]
      helpers = core.scan(/link_to [^,]+, (\w+_path)/).flatten.uniq -
                %w[admin_general_index_path] - removed
      expect(helpers.reject { |helper| ours.include?(helper) }).to eq([])
    end
  end

  describe 'Things to do' do
    it 'leaves out requests whose replies their requesters haven’t classified' do
      FactoryBot.create(:old_unclassified_request)
      sign_in(admin)
      get '/admin'
      expect(page.at_css('#unclassified')).to be_nil
      expect(response.body).not_to include('still unclassified')
      expect(page.at_css('.admin-lede').text.squish).
        to eq('Nothing is waiting.')
    end

    it 'lists submitted drafts waiting for admin review' do
      ready = make_document
      ready.log!('review_requested', user: owner)
      sign_in(admin)
      get '/admin'
      expect(response.body).
        not_to include('No pending administration required')
      mine = page.css('details.admin-todo--mine').find do
        _1.at_css('summary').text.include?('Ready for you to check')
      end
      expect(mine.css('.admin-rows__title').map(&:text)).to eq([ready.title])
      expect(mine.at_css('.admin-rows__act a')['href']).
        to eq("/documents/#{ready.public_id}/manage")

      today = page.css('details.admin-todo summary').map { _1.text.squish }

      document_request :get, '/documents/review'
      expect(page.at_css('body.admin #admin-bar')).to be_present
      expect(page.at_css('#banner')).to be_nil
      expect(page.css('details.admin-todo summary').map { _1.text.squish }).
        to eq(today)
    end

    it 'lists a document withdrawn after a rule change, until an admin publishes it again' do
      document = publish(make_document, by: admin)
      document.withdraw!(kind: 'source_changed', reason: 'Rule matched')
      sign_in(admin)
      get '/admin'
      group = page.css('details.admin-todo').find do
        _1.at_css('summary').text.include?(
          Disclosures::ReviewQueue::SOURCE_CHANGED
        )
      end
      expect(group.css('.admin-rows__title').map(&:text)).
        to eq([document.title])
    end

    it 'lists a requester’s attachment draft that only an admin can confirm, while requesters can’t publish' do
      attachment = make_document.foi_attachment
      allow(Disclosures).to receive(:requester_editing?).and_return(false)
      revision = AttachmentManagement::Revision.new(
        kind: 'upload',
        status: 'ready',
        user: owner,
        foi_attachment: attachment,
        source_sha256: 'a' * 64,
        source_content_type: 'text/plain',
        source_filename: 'runs.txt'
      )
      revision.save!(validate: false)
      sign_in(admin)
      get '/admin'
      expect(page.at_css('#todo-attachments').parent.text).
        to include('Drafts only an admin can confirm', 'runs.txt')
    end

    it 'leaves the attachment drafts out while requesters publish their own' do
      allow(Disclosures).to receive(:requester_editing?).and_return(true)
      sign_in(admin)
      get '/admin'
      expect(page.at_css('#todo-attachments')).to be_nil
    end

    it 'says so when nothing waits' do
      sign_in(admin)
      get '/admin'
      expect(page.css('.admin-clear').map { _1.text.squish }).
        to include(a_string_starting_with('No drafts'))
    end

    it 'shows the newest 50 misdelivered replies under the count of them all' do
      holding = InfoRequest.holding_pen_request
      first = FactoryBot.create(:incoming_message, info_request: holding)
      first.update_columns(
        cached_main_body_text_folded: 'Misdelivered reply 0',
        cached_main_body_text_unfolded: 'Misdelivered reply 0'
      )
      IncomingMessage.insert_all(Array.new(54) do |index|
        text = "Misdelivered reply #{index + 1}"
        first.attributes.except('id').
          merge('created_at' => first.created_at + (index + 1).minutes,
                'cached_main_body_text_folded' => text,
                'cached_main_body_text_unfolded' => text)
      end)
      sign_in(admin)
      get '/admin'
      list = page.at_css('#holding-pen')
      shown = list.css('.admin-rows__title').map { _1.text.squish }
      expect(list.at_css('summary .admin-todo__count').text.squish).
        to eq('55')
      expect(shown.size).to eq(50)
      expect(shown).to eq((5..54).map { "Misdelivered reply #{_1}" })
    end
  end

  describe 'the admin request and authority pages' do
    it 'offer only the two prominences a request can have' do
      sign_in(admin)
      get "/admin/requests/#{info_request.id}/edit"
      expect(page.css('#info_request_prominence option').map { _1['value'] }).
        to eq(%w[requester_only hidden])
    end

    it 'hides and unhides a request inline with a reason' do
      sign_in(admin)
      get "/admin/requests/#{info_request.id}"
      expect(page.at_css('#request-prominence')).to be_present
      reason_field = '#request-prominence textarea[name="prominence_reason"]'
      expect(page.at_css(reason_field)).to be_present
      expect(page.text).to include('Hide from requester')

      patch prominence_admin_request_path(info_request),
            params: { prominence: 'hidden', prominence_reason: 'Personal data' }
      expect(response).to redirect_to(admin_request_url(info_request))
      expect(info_request.reload.prominence).to eq('hidden')
      expect(info_request.prominence_reason).to eq('Personal data')

      get "/admin/requests/#{info_request.id}"
      expect(page.text).
        to include('Hidden from the requester.', 'Personal data')
      unhide_btn = '#request-prominence input[value="Unhide for requester"]'
      expect(page.at_css(unhide_btn)).to be_present
    end

    it 'sum up the request: who sees it, its documents and each file’s state, with the raw fields folded' do
      document = publish(make_document, by: admin)
      sign_in(admin)
      get "/admin/requests/#{info_request.id}"
      facts = page.css('.admin-facts > div').to_h do
        [_1.at_css('dt').text, _1.at_css('dd').text.squish]
      end
      expect(facts['Who sees it']).
        to eq('Only the requester and admins. This is the default.')
      expect(page.at_css('.admin-documents td a').text).to eq(document.title)
      expect(page.at_css('.admin-files li').text.squish).
        to include('runs.txt', 'Published', document.title)
      expect(page.at_css('details.admin-all summary').text).to eq('All fields')
      expect(response.body).
        not_to include('Public page:', 'This request has already been hidden')
    end

    it 'puts an authority’s address, groups, map, documents and releases first' do
      release = AuthorityGroups::ExternalRelease.create!(
        public_body: body,
        title: 'Synthetic release',
        url: 'https://example.invalid/r',
        released_on: Date.new(2026, 9, 1)
      )
      publish(make_document, by: admin)
      sign_in(admin)
      get "/admin/bodies/#{body.id}"
      expect(page.css('.admin-facts dt').map(&:text)).
        to include('FOI address', 'Groups', 'Map', 'Home page')
      expect(page.css('.admin-counts b').map(&:text)).to eq(%w[1 1 1])
      row = page.css('.admin-releases tr').find do
        _1.text.include?('Synthetic release')
      end
      expect(row.css('form').map { _1['action'] }).
        to eq(["/admin/external_releases/#{release.id}/hide",
               "/admin/external_releases/#{release.id}/pin"])
      expect(page.at_css('details.admin-all summary').text).to eq('All fields')
    end
  end

  describe 'a document’s take-down actions' do
    it 'asks for a tick before deleting a draft, and says what each action does' do
      document = make_document
      sign_in(admin)
      document_request :get, "/documents/#{document.public_id}/manage"
      box = page.at_css('.document-remove')
      expect(box.css('summary').map { _1.text.squish }).
        to include('Delete this draft Permanent')
      expect(box.at_css('input[name="confirm"][required]')).to be_present
      document_request :delete, "/documents/#{document.public_id}/manage"
      expect(flash[:error]).to eq('Tick that you want to delete the draft.')
      expect(Disclosures::Document.exists?(document.id)).to be(true)
      document_request :delete, "/documents/#{document.public_id}/manage",
                       params: { confirm: '1' }
      expect(Disclosures::Document.exists?(document.id)).to be(false)
    end
  end
end
