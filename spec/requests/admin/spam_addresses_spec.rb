require 'spec_helper'

RSpec.describe 'Admin spam addresses', type: :request do
  # Arrange a fully authenticated admin; production has no test-only bypass.
  before { sign_in users(:admin_user) }

  let(:page) { Nokogiri::HTML(response.body) }

  def listed_emails
    page.css('table tbody tr td:first-child').map(&:text)
  end

  describe 'GET index' do
    it 'lists the spam addresses' do
      FactoryBot.create_list(:spam_address, 3)
      get admin_spam_addresses_path
      expect(response).to have_http_status(:ok)
      expect(listed_emails).to match_array(SpamAddress.pluck(:email))
    end

    it 'shows an empty form for a new spam address' do
      get admin_spam_addresses_path
      form = page.at_css('form#new_spam_address')
      expect(form['action']).to eq(admin_spam_addresses_path)
      expect(form.at_css('input[name="spam_address[email]"]')['value']).
        to be_nil
    end

    it 'shows the spam addresses page' do
      get admin_spam_addresses_path
      expect(page.at_css('h1').text).to eq('Spam Addresses')
    end
  end

  describe 'POST create' do
    let(:spam_params) { FactoryBot.attributes_for(:spam_address) }

    it 'creates a new spam address with the given parameters' do
      expect {
        post admin_spam_addresses_path, params: { spam_address: spam_params }
      }.to change(SpamAddress, :count).by(1)
      expect(SpamAddress.last.email).to eq(spam_params[:email])
    end

    it 'redirects to the index action if successful' do
      post admin_spam_addresses_path, params: { spam_address: spam_params }
      expect(response).to redirect_to(admin_spam_addresses_path)
    end

    it 'notifies the admin the spam address has been created' do
      post admin_spam_addresses_path, params: { spam_address: spam_params }
      msg = "#{ spam_params[:email] } has been added to the spam addresses list"
      expect(flash[:notice]).to eq(msg)
    end

    context 'when the address could not be saved' do
      before do
        FactoryBot.create_list(:spam_address, 3)
        allow_any_instance_of(SpamAddress).to receive(:save).and_return(false)
        post admin_spam_addresses_path, params: { spam_address: spam_params }
      end

      it 'shows the index page again with the address in the form' do
        expect(response).to have_http_status(:unprocessable_content)
        expect(page.at_css('h1').text).to eq('Spam Addresses')
        field = page.at_css('input[name="spam_address[email]"]')
        expect(field['value']).to eq(spam_params[:email])
      end

      it 'lists the spam addresses' do
        expect(listed_emails).to match_array(SpamAddress.pluck(:email))
        expect(listed_emails.size).to eq(3)
      end
    end
  end

  describe 'DELETE destroy' do
    let!(:spam) { FactoryBot.create(:spam_address) }
    let!(:other_spam) { FactoryBot.create(:spam_address) }

    before { delete admin_spam_address_path(spam) }

    it 'destroys the given spam address and no other' do
      expect(SpamAddress).not_to exist(spam.id)
      expect(SpamAddress).to exist(other_spam.id)
    end

    it 'tells the admin the spam address has been deleted' do
      msg = "#{ spam.email } has been removed from the spam addresses list"
      expect(flash[:notice]).to eq(msg)
    end

    it 'redirects to the index action' do
      expect(response).to redirect_to(admin_spam_addresses_path)
    end
  end
end
