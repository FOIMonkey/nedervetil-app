require 'spec_helper'

RSpec.describe 'Reporting a request', type: :request do
  let(:info_request) { FactoryBot.create(:info_request) }
  let(:user) { info_request.user }

  # Signs in through the form and checks it worked, so that a refusal later
  # in the example is not a failed sign-in.
  def sign_in_as(user)
    sign_in(user)
    expect(response).to have_http_status(:see_other)
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def offered_reasons
    page.css('select#reason option').map(&:text) - ['Choose a reason']
  end

  def report(params = {})
    post request_report_path(info_request.url_title),
         params: { reason: 'my reason' }.merge(params)
  end

  describe 'POST create' do
    context 'when not logged in' do
      it 'only allows logged-in users to report requests' do
        report
        expect(response).to have_http_status(:not_found)
        expect(info_request.reload.attention_requested).to be(false)
      end
    end

    context 'when logged in' do
      before do
        sign_in_as user
      end

      it 'reports the request named in the URL' do
        other_request = FactoryBot.create(:info_request, user: user)
        report
        expect(response).
          to redirect_to show_request_url(info_request.url_title)
        expect(info_request.reload.attention_requested).to be(true)
        expect(other_request.reload.attention_requested).to be(false)
      end

      it 'offers the request report reasons when a reason is missing' do
        report(reason: '')
        expect(offered_reasons).to eq(info_request.report_reasons)
      end

      it 'logs an event' do
        report
        last_event = info_request.reload.last_event
        expect(last_event.event_type).to eq('report_request')
        expect(last_event.params).to eq(
          request: { gid: info_request.to_global_id.to_s },
          editor: { gid: user.to_global_id.to_s },
          reason: 'my reason',
          message: '',
          old_attention_requested: false,
          attention_requested: true
        )
      end

      it 'is not found for non-existent requests' do
        post request_report_path('hjksfdhjk_louytu_qqxxx')
        expect(response).to have_http_status(:not_found)
      end

      it 'marks a request as having been reported' do
        expect(info_request.attention_requested).to eq(false)

        report
        expect(response).
          to redirect_to show_request_path(info_request.url_title)

        info_request.reload
        expect(info_request.attention_requested).to eq(true)
        expect(info_request.described_state).to eq('attention_requested')
      end

      it 'sets the flash message when the request gets successfully ' \
         'reported' do
        expected = 'This request has been reported for administrator attention'

        report(message: "It's just not")

        expect(flash[:notice]).to eq(expected)
      end

      it 'does not allow a request to be reported twice' do
        report
        expect(response).
          to redirect_to show_request_url(info_request.url_title)

        report
        expect(response).
          to redirect_to show_request_url(info_request.url_title)
        expect(flash[:notice]).to match(/has already been reported/)
      end

      it 'sends an email from the reporter to admins' do
        report(message: "It's just not")
        deliveries = ActionMailer::Base.deliveries
        expect(deliveries.size).to eq(1)
        mail = deliveries[0]
        expect(mail.subject).to match(/attention_requested/)
        expect(mail.header['Reply-To'].to_s).to include(user.email)
        expect(mail.body).to include(user.name)
        expect(mail.body).
          to include("Reason: my reason\n\nIt's just not")
      end

      # A suspended account sees its request but can't report it.
      it 'refuses a suspended account' do
        user.update!(ban_text: 'Banned')
        report
        expect(response).to have_http_status(:unprocessable_content)
        expect(page.at_css('h1.page-band__title').text).
          to eq('Banned from this site')
        expect(info_request.reload.attention_requested).to be(false)
      end

      it 'forces the user to pick a reason' do
        report(reason: '')
        expect(response).to have_http_status(:unprocessable_content)
        expect(page.at_css("form[action='#{request_report_path(
          info_request.url_title
        )}'] select#reason")).to be_present
        expect(flash[:error]).to eq('Please choose a reason')
        expect(info_request.reload.attention_requested).to be(false)
      end
    end
  end

  describe 'GET new' do
    context 'when not logged in' do
      it 'requires the user to be logged in' do
        get new_request_report_path(info_request.url_title)
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when logged in' do
      before do
        sign_in_as user
      end

      it 'shows the report form for the request, with its title' do
        get new_request_report_path(info_request.url_title)
        expect(response).to have_http_status(:ok)
        expect(page.at_css('h1.page-band__title').text).
          to eq("Report request: #{info_request.title}")
        expect(page.at_css('title').text).
          to include("Report request: #{info_request.title}")
        form = page.at_css(
          "form[action='#{request_report_path(info_request.url_title)}']"
        )
        expect(form).to be_present
        expect(form.at_css('textarea#message')).to be_present
      end

      it 'offers the request report reasons' do
        get new_request_report_path(info_request.url_title)
        expect(offered_reasons).to eq(info_request.report_reasons)
      end

      it 'is not found for non-existent requests' do
        get new_request_report_path('hjksfdhjk_louytu_qqxxx')
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
