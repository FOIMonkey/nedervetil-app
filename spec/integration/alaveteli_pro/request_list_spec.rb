require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe "pro request list" do
  let(:pro_user) { FactoryBot.create(:pro_user) }
  let(:public_body) { FactoryBot.create(:public_body) }
  let!(:pro_user_session) { login(pro_user) }
  let!(:info_requests) do
    FactoryBot.create_list(:info_request,
                           3,
                           user: pro_user,
                           public_body: public_body)
  end

  let(:public_bodies) do
    FactoryBot.create_list(:public_body, 2)
  end

  let!(:batch_requests) do
    FactoryBot.create_list(
      :info_request_batch,
      5,
      user: pro_user,
      public_bodies: public_bodies
    )
  end

  before do
    # Send 4 out of 5 of the batch requests
    batch_requests[0..3].each do |batch|
      batch.create_batch!
      batch.update(sent_at: Time.zone.now)
      batch.reload
    end
  end

  it "shows requests that have been made" do
    using_pro_session(pro_user_session) do
      visit(alaveteli_pro_info_requests_path)
      request = info_requests.last
      row = ".pile__row[data-request-id='#{request.id}']"
      expect(page).to have_css(row)

      within(row) do
        request_path = show_request_path(request.url_title)
        due = Deadlines::Overview.format_date(request.date_response_required_by)
        expect(page).to have_link(request.title, href: request_path)
        expect(page).to have_content("Response due #{due}")
        expect(page).to have_content(request.public_body.name)
      end
    end
  end

  it "shows batch requests alongside other requests" do
    using_pro_session(pro_user_session) do
      visit(alaveteli_pro_info_requests_path)
      batch = batch_requests.first

      expect(batch.info_requests.first.state.phase).to eq(:awaiting_response)
      expect(batch.request_summary.request_summary_categories).
        to eq([AlaveteliPro::RequestSummaryCategory.awaiting_response])

      within("#pile-waiting") do
        expect(page).
          to have_css(".pile__row[data-request-id='#{info_requests.last.id}']")

        batch.info_requests.each do |request|
          within(".pile__row[data-request-id='#{request.id}']") do
            request_path = show_request_path(request.url_title)
            expect(page).to have_link(batch.title, href: request_path)
            expect(page).to have_content(request.public_body.name)
            expect(page).to have_content("Response due")
          end
        end
      end
    end
  end

  it "lists the requests in a batch only once the batch has been sent" do
    using_pro_session(pro_user_session) do
      visit(alaveteli_pro_info_requests_path)
      batch = batch_requests.last
      sent = info_requests + batch_requests[0..3].flat_map(&:info_requests)

      expect(batch.info_requests).to be_empty
      expect(page).to have_css(".pile__row", count: sent.size)
      sent.each do |request|
        expect(page).to have_css(".pile__row[data-request-id='#{request.id}']")
      end
    end
  end

  describe "showing draft requests" do
    let!(:draft_request) do
      FactoryBot.create(:draft_info_request, user: pro_user,
                                             title: 'Grit bin sites')
    end
    let!(:draft_batch_request) do
      FactoryBot.create(
        :draft_info_request_batch,
        user: pro_user,
        public_bodies: public_bodies
      )
    end

    it "shows draft requests" do
      using_pro_session(pro_user_session) do
        visit(alaveteli_pro_info_requests_path)
        click_link "Drafts"

        draft_path = new_alaveteli_pro_info_request_path(
          draft_id: draft_request.id
        )
        expect(page).to have_link(draft_request.title, href: draft_path)
      end
    end

    it "deletes a draft from its row" do
      using_pro_session(pro_user_session) do
        visit(alaveteli_pro_info_requests_path)
        click_link "Drafts"

        # rack_test cannot open a <details>, so the button is pressed closed.
        within(".pile__row", text: draft_request.title) do
          expect(page).to have_css("summary", text: "Delete")
          click_button "Delete this draft", visible: :all
        end

        expect(page).to have_content("Draft deleted.")
        expect(page).to have_no_link(draft_request.title)
      end
    end

    it "says there are no drafts once the only one is deleted" do
      using_pro_session(pro_user_session) do
        visit(alaveteli_pro_info_requests_path)
        click_link "Drafts"
        click_button "Delete this draft", visible: :all

        expect(page).to have_content("No drafts.")
        expect(page).to have_link("See all requests",
                                  href: alaveteli_pro_info_requests_path)
        expect(page).to have_no_link("Drafts")
      end
    end

    it "lists draft requests only, as batches are never offered" do
      using_pro_session(pro_user_session) do
        visit(alaveteli_pro_info_requests_path)
        click_link "Drafts"

        expect(page).to have_link(draft_request.title)
        expect(page).
          to have_no_css("#draft-info-request-batch-#{draft_batch_request.id}")
      end
    end
  end
end
