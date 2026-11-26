require 'spec_helper'

RSpec.describe 'Batch request page', type: :request do
  let(:first_public_body) { FactoryBot.create(:public_body) }
  let(:second_public_body) { FactoryBot.create(:public_body) }
  let(:bodies) { [first_public_body, second_public_body] }
  let!(:info_request_batch) do
    FactoryBot.create(:info_request_batch, title: 'Matched title',
                                           body: 'Matched body',
                                           public_bodies: bodies)
  end
  let(:pro_user) { FactoryBot.create(:pro_user) }
  let(:page) { Nokogiri::HTML(response.body) }

  # Signs in and checks it worked, so that a refusal which follows is the
  # page's own and not a failed sign-in.
  def heading
    page.at_css('h1.page-band__title').text
  end

  def request_titles
    page.css('.request_listing .head a').map { _1.text.strip }
  end

  def body_names
    page.css('.body_listing .head a').map { _1.text.strip }
  end

  def in_pro_area?
    page.at_css('body')['class'].to_s.split.include?('alaveteli-pro')
  end

  describe 'GET show' do
    # The requester's own private batch is shown in the inbox; the plain URL
    # redirects there.
    it 'is shown to its requester in the inbox' do
      sign_in info_request_batch.user
      get show_alaveteli_pro_batch_request_path(info_request_batch)
      expect(response).to have_http_status(:ok)
      expect(heading).to eq('Matched title - a batch request')
    end

    it 'sends its requester from the plain URL to that batch in the inbox' do
      sign_in info_request_batch.user
      get info_request_batch_path(info_request_batch)
      expect(response).to redirect_to(
        show_alaveteli_pro_batch_request_url(info_request_batch)
      )
      follow_redirect!
      expect(heading).to eq('Matched title - a batch request')
    end

    context 'when the batch has not been sent' do
      it 'lists the authorities it will go to' do
        sign_in info_request_batch.user
        get show_alaveteli_pro_batch_request_path(info_request_batch)
        expect(response.body).
          to include('Requests will be sent to the following bodies:')
        expect(body_names).to match_array(bodies.map(&:name))
        expect(request_titles).to be_empty
      end
    end

    describe 'the requests listed' do
      context 'when the batch has been sent' do
        before do
          FactoryBot.create(
            :info_request,
            title: 'First request',
            info_request_batch: info_request_batch,
            user: info_request_batch.user,
            public_body: first_public_body
          )
          FactoryBot.create(
            :info_request,
            title: 'Second request',
            info_request_batch: info_request_batch,
            user: info_request_batch.user,
            public_body: second_public_body
          )
          FactoryBot.create(
            :hidden_request,
            title: 'Hidden request',
            info_request_batch: info_request_batch,
            user: info_request_batch.user
          )
          FactoryBot.create(
            :requester_only_request,
            title: 'Requester only request',
            info_request_batch: info_request_batch,
            user: info_request_batch.user
          )
          info_request_batch.update!(sent_at: Time.zone.now)
        end

        context 'when viewed in the pro area' do
          before do
            sign_in info_request_batch.user
            get show_alaveteli_pro_batch_request_path(info_request_batch)
          end

          it 'lists the requests visible to the requester' do
            expect(request_titles).to match_array(
              ['First request', 'Second request', 'Requester only request']
            )
            expect(body_names).to be_empty
          end

          it 'leaves out requests hidden from the requester' do
            expect(request_titles).not_to include('Hidden request')
          end
        end
      end
    end

    describe 'when params[:pro] is true' do
      it 'is shown in the inbox area' do
        sign_in info_request_batch.user
        get show_alaveteli_pro_batch_request_path(info_request_batch)
        expect(response).to have_http_status(:ok)
        expect(in_pro_area?).to be true
      end
    end

    describe 'redirecting private batches' do
      context 'when showing requesters their own requests' do
        it 'redirects to the inbox version of the page, as it is private' do
          batch = FactoryBot.create(:info_request_batch,
                                    user: pro_user, public_bodies: bodies)
          sign_in pro_user
          get info_request_batch_path(batch)
          expect(response).
            to redirect_to show_alaveteli_pro_batch_request_url(batch)
        end

        it 'does the same for any account' do
          user = FactoryBot.create(:user)
          batch = FactoryBot.create(:info_request_batch,
                                    user: user, public_bodies: bodies)
          sign_in user
          get info_request_batch_path(batch)
          expect(response).
            to redirect_to show_alaveteli_pro_batch_request_url(batch)
        end
      end

      context "when showing someone else's request" do
        it 'is not found' do
          sign_in! pro_user
          get info_request_batch_path(info_request_batch)
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    describe 'accessing private batches' do
      let(:batch) do
        FactoryBot.create(:info_request_batch,
                          public_bodies: bodies, user: pro_user)
      end
      let(:admin) { FactoryBot.create(:admin_user) }
      let(:other_pro_user) { FactoryBot.create(:pro_user) }
      let(:other_user) { FactoryBot.create(:user) }

      it 'allows the owner to access it' do
        sign_in pro_user
        get show_alaveteli_pro_batch_request_path(batch)
        expect(response).to have_http_status(:ok)
        expect(heading).to eq("#{batch.title} - a batch request")
      end

      it 'allows admins to access it' do
        sign_in admin
        get info_request_batch_path(batch)
        expect(response).to have_http_status(:ok)
        expect(heading).to eq("#{batch.title} - a batch request")
      end

      it 'is not found for other accounts like the owner' do
        sign_in! other_pro_user
        get info_request_batch_path(batch)
        expect(response).to have_http_status(:not_found)
      end

      it 'is not found for other accounts' do
        sign_in! other_user
        get info_request_batch_path(batch)
        expect(response).to have_http_status(:not_found)
      end

      it 'is not found for visitors who are not signed in' do
        get info_request_batch_path(batch)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
