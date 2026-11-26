require 'spec_helper'

RSpec.describe 'Help pages', type: :request do
  let(:page) { Nokogiri::HTML(response.body) }

  # Core help pages are placeholders; prepend the fixture theme on the instance
  # so class-level view paths are not mutated.
  def with_fixture_theme
    theme = Rails.root.join('spec', 'fixtures', 'theme_views', 'theme_one')
    allow_any_instance_of(HelpController).
      to receive(:contact).and_wrap_original do |original, *args|
        original.receiver.prepend_view_path(theme)
        original.call(*args)
      end
    yield
  end

  describe 'GET unhappy' do
    let(:info_request) { FactoryBot.create(:info_request) }

    it 'shows the unhappy page about no request in particular' do
      get help_unhappy_path
      expect(response).to have_http_status(:ok)
      expect(page.css('h1').map(&:text)).
        to include(a_string_including('Not happy with a reply?'))
      expect(response.body).not_to include('About your request')
      expect(response.body).not_to include('Ask for an internal review</a>')
    end

    context 'when a url_title param is supplied' do
      it 'shows the page about that request' do
        sign_in info_request.user
        get help_unhappy_path(url_title: info_request.url_title)
        expect(response).to have_http_status(:ok)
        expect(page.text).to include('About your request')
        expect(page.text).to include(info_request.title)
        expect(response.body).to include(
          new_request_followup_path(info_request.url_title,
                                    internal_review: 1)
        )
        expect(page.at_css('.case-file')).to be_present
      end

      it 'is not found if the InfoRequest is not found' do
        get help_unhappy_path(url_title: 'something_not_existing')
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'GET about' do
    it 'shows the about page' do
      get help_about_path
      expect(response).to be_successful
      expect(response.body).to include('Placeholder to be overridden by theme')
    end
  end

  describe 'GET contact' do
    it 'shows contact form' do
      with_fixture_theme { get help_contact_path }
      expect(response).to be_successful
      expect(response.body).to include('Contact us')
    end

    describe 'when requesting a page in a supported locale' do
      it 'should render the locale-specific template if available' do
        cookies[:locale] = 'es'
        with_fixture_theme { get help_contact_path }
        expect(response.body).to match('contáctenos theme one')
      end
    end
  end

  describe 'POST contact' do
    let(:contact) do
      { name: 'Vinny Vanilli',
        email: 'vinny@localhost',
        subject: 'Why do I have such an ace name?',
        comment: '',
        message: "You really should know!!!\n\nVinny" }
    end

    def send_message(fields = contact)
      post help_contact_path,
           params: { contact: fields, submitted_contact_form: 1 }
    end

    def sent_body
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      ActionMailer::Base.deliveries[0].body.to_s
    end

    it 'sends a contact message' do
      send_message
      expect(response).to redirect_to(frontpage_path)
      expect(sent_body).to include('really should know')
    end

    context 'when a last_request_id cookie is set' do
      let(:info_request) { FactoryBot.create(:info_request) }

      context 'when the user can access the specified request' do
        it 'names the request in the message' do
          sign_in info_request.user
          cookies[:last_request_id] = info_request.id.to_s
          send_message
          path = show_request_path(info_request.url_title)
          expect(sent_body).to match(%r{Last request viewed: \S*#{path}\b})
        end
      end

      context "when the user can't access the specified request" do
        it 'leaves the request out of the message' do
          info_request = FactoryBot.create(:info_request, :requester_only)
          user = FactoryBot.create(:user)
          sign_in user
          cookies[:last_request_id] = info_request.id.to_s
          send_message
          body = sent_body
          path = show_user_path(user.url_name)
          expect(body).to match(%r{logged in as user \S*#{path}\b})
          expect(body).not_to include('Last request viewed')
          expect(body).not_to include(info_request.url_title)
        end
      end

      context 'when the request cannot be found' do
        it 'leaves the request out of the message' do
          cookies[:last_request_id] = (InfoRequest.maximum(:id).to_i + 1).to_s
          send_message
          expect(sent_body).not_to include('Last request viewed')
        end
      end
    end

    context 'when a last_body_id cookie is set' do
      let(:body) { FactoryBot.create(:public_body) }

      it 'names the authority in the message' do
        cookies[:last_body_id] = body.id.to_s
        send_message
        path = show_public_body_path(body.url_name)
        expect(sent_body).to match(%r{Last authority viewed: \S*#{path}\b})
      end

      context 'when the body cannot be found' do
        it 'leaves the authority out of the message' do
          cookies[:last_body_id] = (PublicBody.maximum(:id).to_i + 1).to_s
          send_message
          expect(sent_body).not_to include('Last authority viewed')
        end
      end
    end

    context 'when the person check fails' do
      before do
        allow(Turnstile).to receive(:check).and_return(:failed)
      end

      let(:contact) do
        { name: 'Possible Spammmer',
          email: 'spammer@localhost',
          subject: 'Can I sell you my book?',
          comment: '',
          message: "It's great, you should buy 1!!" }
      end

      it 'does not send a signed-out visitor’s message' do
        send_message
        expect(response).not_to redirect_to(frontpage_path)
        expect(flash[:error]).
          to include("couldn't confirm that you're a person")
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(Turnstile).to have_received(:check).
          with(anything, hash_including(action: 'contact'))
      end

      it 'refuses, and tells the admins, when it can’t answer' do
        allow(Turnstile).to receive(:check).and_return(:unavailable)
        send_message
        expect(flash[:error]).to include("can't check this form")
        expect(ActionMailer::Base.deliveries.map(&:subject).join).
          to include("Turnstile couldn't check the contact form")
      end

      it 'does not ask someone signed in' do
        sign_in FactoryBot.create(:user)
        send_message
        expect(response).to redirect_to(frontpage_path)
        expect(ActionMailer::Base.deliveries.size).to eq(1)
      end
    end

    it 'has rudimentary spam protection' do
      send_message(contact.merge(comment: 'I AM A SPAMBOT'))
      expect(response).to redirect_to(frontpage_path)
      expect(ActionMailer::Base.deliveries.size).to eq(0)
    end

    it 'renders the form when no params are supplied' do
      with_fixture_theme { post help_contact_path }
      expect(response).to be_successful
      expect(response.body).to include('Contact us')
    end

    it 'does not accept a form without a comment param' do
      send_message(contact.except(:comment))
      expect(response).to redirect_to(frontpage_path)
    end
  end
end
