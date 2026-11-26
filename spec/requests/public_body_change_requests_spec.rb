require 'spec_helper'

RSpec.describe 'Authority change request pages', type: :request do
  let(:page) { Nokogiri::HTML(response.body) }

  def change_request_form
    page.at_css("form[action='#{change_request_path}']")
  end

  describe 'GET new' do
    before do
      allow(Turnstile).to receive_messages(configured?: true,
                                           site_key: 'site-key')
    end

    it 'shows the form' do
      get new_change_request_path
      expect(response).to have_http_status(:ok)
      expect(change_request_form).to be_present
      expect(response.body).to include('Ask us to add an authority')
      expect(page.at_css('input[name="public_body_change_request' \
                         '[public_body_name]"]')).to be_present
    end

    it 'asks a signed-out visitor for the person check' do
      get new_change_request_path
      expect(page.at_css('.cf-turnstile')).to be_present
    end

    it 'names the person check as the controller checks it' do
      get new_change_request_path
      expect(response.body).to include('data-action="change_request"')
    end

    it 'does not ask someone signed in for the person check' do
      sign_in FactoryBot.create(:user)
      get new_change_request_path
      expect(change_request_form).to be_present
      # Only a signed-out visitor is asked for a name.
      expect(page.at_css('input[name="public_body_change_request' \
                         '[user_name]"]')).to be_nil
      expect(page.at_css('.cf-turnstile')).to be_nil
    end
  end

  describe 'POST create' do
    let(:email) { 'test@example.com' }
    let(:change_request_params) do
      { user_email: email,
        user_name: 'Test User',
        public_body_name: 'New Body',
        public_body_email: 'new_body@example.com',
        notes: 'Please',
        source: 'http://www.example.com',
        comment: '' }
    end

    def submit(params = change_request_params)
      post change_request_path,
           params: { public_body_change_request: params }
    end

    it 'should send an email to the site contact address' do
      expect { submit }.to change(PublicBodyChangeRequest, :count).by(1)
      change_request_id = PublicBodyChangeRequest.last.id
      deliveries = ActionMailer::Base.deliveries
      expect(deliveries.size).to eq(1)
      mail = deliveries[0]
      expect(mail.subject).to match(/Add authority - New Body/)
      expect(mail.header['Reply-To'].to_s).to include(email)
      expect(mail.to).to include('postmaster@localhost')
      expect(mail.body).to include('new_body@example.com')
      expect(mail.body).to include('New Body')
      expect(mail.body).to include('Please')
      expect(mail.body).to include(
        'http://test.host/admin/bodies/new?change_request_id=' \
        "#{change_request_id}"
      )
      expect(mail.body).to include(
        "http://test.host/admin/change_requests/#{change_request_id}/edit"
      )
    end

    it 'checks a signed-out visitor is a person' do
      expect(Turnstile).to receive(:check).
        with(anything, hash_including(action: 'change_request')).
        and_return(:passed)
      submit
      expect(response).to redirect_to(frontpage_url)
    end

    it 'does not check someone signed in' do
      sign_in FactoryBot.create(:user)
      expect(Turnstile).not_to receive(:check)
      expect { submit }.to change(PublicBodyChangeRequest, :count).by(1)
      expect(response).to redirect_to(frontpage_url)
    end

    it 'refuses, and tells the admins, when the person check can’t answer' do
      allow(Turnstile).to receive(:check).and_return(:unavailable)
      expect { submit }.not_to change(PublicBodyChangeRequest, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(change_request_form).to be_present
      expect(page.text).to include("can't check this form")
      expect(ActionMailer::Base.deliveries.map(&:subject).join).
        to include("Turnstile couldn't check the change_request form")
    end

    it 're-renders the form, sending nothing, if the person check fails' do
      allow(Turnstile).to receive(:check).and_return(:failed)
      expect { submit }.not_to change(PublicBodyChangeRequest, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(change_request_form).to be_present
      expect(page.text).to include("couldn't confirm that you're a person")
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'should show a notice' do
      submit
      expected_text = 'Your request to add an authority has been sent. ' \
                      "Thank you for getting in touch! We'll get back to " \
                      'you soon.'
      expect(flash[:notice]).to eq(expected_text)
    end

    it 'should redirect to the frontpage' do
      submit
      expect(response).to redirect_to frontpage_url
    end

    it 'has rudimentary spam protection' do
      expect { submit(change_request_params.merge(comment: 'I AM A SPAMBOT')) }.
        not_to change(PublicBodyChangeRequest, :count)

      expect(response).to redirect_to(frontpage_path)
      expect(ActionMailer::Base.deliveries.size).to eq(0)
    end

    context 'when handling a request for an update to an existing authority' do
      let(:public_body) { FactoryBot.create(:public_body) }
      let(:change_request_params) do
        { user_email: email,
          user_name: 'Test User',
          public_body_id: public_body.id,
          public_body_email: 'new_body@example.com',
          notes: 'Please',
          source: 'http://www.example.com',
          comment: '' }
      end

      it 'should send an email to the site contact address' do
        submit
        change_request_id = PublicBodyChangeRequest.last.id
        deliveries = ActionMailer::Base.deliveries
        expect(deliveries.size).to eq(1)
        mail = deliveries[0]
        expect(mail.subject).
          to match(/Update email address - #{public_body.name}/)
        expect(mail.header['Reply-To'].to_s).to include(email)
        expect(mail.to).to include('postmaster@localhost')
        expect(mail.body).to include('new_body@example.com')
        expect(mail.body).to include(public_body.name)
        expect(mail.body).to include('Please')
        expect(mail.body).to include('http://test.host/admin/bodies/' \
          "#{public_body.id}/edit?change_request_id=#{change_request_id}")
        expect(mail.body).to include('http://test.host/admin/' \
          "change_requests/#{change_request_id}/edit")
      end

      it 'should show a notice' do
        submit
        expected_text = 'Your request to update the address for ' \
                        "#{public_body.name} has been sent. Thank you for " \
                        "getting in touch! We'll get back to you soon."
        expect(flash[:notice]).to eq(expected_text)
      end

      it 'should redirect to the frontpage' do
        submit
        expect(response).to redirect_to frontpage_url
      end
    end
  end
end
