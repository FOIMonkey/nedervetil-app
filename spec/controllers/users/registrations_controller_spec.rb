require 'spec_helper'

RSpec.describe Users::RegistrationsController do
  render_views
  before { @request.env['devise.mapping'] = Devise.mappings[:user] }
  context 'with the person check' do
    let(:signup) do
      { user_signup: { email: 'new@localhost', name: 'New Person' } }
    end

    it 'makes no account when it fails' do
      allow(Turnstile).to receive(:check).and_return(:failed)
      expect { post :create, params: signup }.not_to change(User, :count)
      expect(response).to have_http_status(422)
      expect(flash[:error]).
        to include("couldn't confirm that you're a person")
    end

    it 'makes no account, and tells the admins, when it can’t answer' do
      allow(Turnstile).to receive(:check).and_return(:unavailable)
      expect { post :create, params: signup }.not_to change(User, :count)
      expect(flash[:error]).to include("can't check this form")
      expect(ActionMailer::Base.deliveries.map(&:subject).join).
        to include("Turnstile couldn't check the signup form")
    end

    it 'tells the admins once an hour, however many are refused' do
      allow(Rails).to receive(:cache).
        and_return(ActiveSupport::Cache::MemoryStore.new)
      allow(Turnstile).to receive(:check).and_return(:unavailable)
      2.times { post :create, params: signup }
      expect(ActionMailer::Base.deliveries.map(&:subject).grep(/Turnstile/).
        size).to eq(1)
    end

    it 'only logs when exception mail is off' do
      allow(controller).to receive(:send_exception_notifications?).
        and_return(false)
      allow(Turnstile).to receive(:check).and_return(:unavailable)
      post :create, params: signup
      expect(flash[:error]).to include("can't check this form")
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'is shown on the sign-up form, named as the check names it' do
      allow(Turnstile).to receive_messages(configured?: true,
                                           site_key: 'site-key')
      allow(Turnstile).to receive(:check).and_return(:failed)
      post :create, params: signup
      expect(response.body).to include('cf-turnstile', 'data-action="signup"')
      expect(Turnstile).to have_received(:check).
        with(anything, hash_including(action: 'signup'))
    end
  end

  context 'when signups are in read-only mode' do
    before do
      allow(AlaveteliConfiguration).to receive(:read_only_features).
        and_return(['signups'])
    end

    it 'redirects to the frontpage' do
      post :create, params: {
        user_signup: {
          email: 'new@localhost',
          name: 'New Person'
        }
      }
      expect(response).to redirect_to frontpage_url
    end

    it 'shows a default read only flash message' do
      post :create, params: {
        user_signup: {
          email: 'new@localhost',
          name: 'New Person'
        }
      }
      expect(flash[:notice]).to match(/Alaveteli is currently in maintenance/)
    end
  end

  context 'when site is in general read-only mode' do
    before do
      allow(AlaveteliConfiguration).to receive(:read_only).
        and_return('Database upgrade')
    end

    it 'redirects to the frontpage' do
      post :create, params: {
        user_signup: {
          email: 'new@localhost',
          name: 'New Person'
        }
      }
      expect(response).to redirect_to frontpage_url
    end

    it 'shows a flash message' do
      post :create, params: {
        user_signup: {
          email: 'new@localhost',
          name: 'New Person'
        }
      }
      expect(flash[:notice]).to match(/Database upgrade/)
    end
  end

  context 'using a spammy name or email from a known spam domain' do
    before do
      spam_scorer = double
      allow(spam_scorer).to receive(:spam?).and_return(true)
      allow(UserSpamScorer).to receive(:new).and_return(spam_scorer)
    end

    context 'when BLOCK_SPAM_SIGNUPS is on' do
      before do
        allow(AlaveteliConfiguration).
          to receive(:block_spam_signups).and_return(true)
      end

      it 'logs the signup attempt' do
        msg = "Attempted signup from suspected spammer, " \
              "email: spammer@example.com, " \
              "name: 'Download New Person 1080p!'"
        allow(Rails.logger).to receive(:info)
        expect(Rails.logger).to receive(:info).with(msg)

        post :create, params: {
          user_signup: {
            email: 'spammer@example.com',
            name: 'Download New Person 1080p!'
          }
        }
      end

      it 'blocks the signup' do
        post :create, params: {
          user_signup: {
            email: 'spammer@example.com',
            name: 'New Person'
          }
        }
        expect(User.where(email: 'spammer@example.com').count).to eq(0)
      end

      it 're-renders the form' do
        post :create, params: {
          user_signup: {
            email: 'spammer@example.com',
            name: 'New Person'
          }
        }
        expect(response).to have_http_status(422)
        expect(response.body).to include('id="signup_form"')
        expect(response.body).not_to include('id="signin_form"')
      end
    end

    context 'when BLOCK_SPAM_SIGNUPS is off' do
      before do
        allow(AlaveteliConfiguration).
          to receive(:block_spam_signups).and_return(false)
      end

      it 'sends an exception notification' do
        post :create, params: {
          user_signup: {
            email: 'spammer@example.com',
            name: 'New Person'
          }
        }
        mail = ActionMailer::Base.deliveries.first
        expect(mail.subject).to match(/signup from suspected spammer/)
      end

      it 'allows the signup' do
        post :create, params: {
          user_signup: {
            email: 'spammer@example.com',
            name: 'New Person'
          }
        }
        expect(User.where(email: 'spammer@example.com').count).to eq(1)
      end
    end
  end
end
