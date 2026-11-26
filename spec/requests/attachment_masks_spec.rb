require 'spec_helper'

RSpec.describe 'Attachment masking pages', type: :request do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:attachment) { FactoryBot.build(:body_text, id: 1) }
  let(:verifier) do
    Rails.application.message_verifier('AttachmentsController')
  end
  let(:signed_referer) { verifier.generate('/referer') }
  let(:referer) { signed_referer }

  before do
    sign_in admin
    allow(GlobalID::Locator).to receive(:locate_signed).with('ABC').
      and_return(attachment)
  end

  describe 'GET wait' do
    def wait
      get wait_for_attachment_mask_path('ABC', referer: referer)
    end

    context 'when attachment is masked' do
      it 'redirects to done action' do
        allow(attachment).to receive(:to_signed_global_id).and_return('ABC')
        wait
        expect(response).to redirect_to(
          done_attachment_mask_path('ABC', referer: signed_referer)
        )
      end
    end

    context 'when attachment is unmasked' do
      let(:attachment) { FactoryBot.build(:body_text, :unmasked, id: 1) }

      it 'masks the attachment' do
        expect(attachment).to receive(:mask_later)
        wait
      end

      it 'shows the page asking the visitor to wait' do
        wait
        expect(response).to have_http_status(:ok)
        page = Nokogiri::HTML(response.body)
        expect(page.at_css('h1.page-band__title').text).
          to eq('Attachment processing...')
        expect(page.at_css('[data-controller="wait-reload"]')).to be_present
      end

      it 'sets noindex, nofollow header' do
        wait
        expect(response.headers['X-Robots-Tag']).to eq 'noindex, nofollow'
      end
    end

    # Masking always leaves the requester a copy, even after a fault
    # (FoiAttachment::Maskable#masking_outcome).
    context 'when masking hit a fault and the part waits to be masked again' do
      let(:attachment) do
        FactoryBot.build(
          :body_text, :unmasked, id: 1, masking_failed_at: Time.zone.now
        )
      end

      it 'masks it again' do
        expect(attachment).to receive(:mask_later)
        wait
        expect(response).to be_successful
      end
    end

    context "when attachment can't be found" do
      it 'answers not found' do
        expect_signed_in_as(admin)
        allow(GlobalID::Locator).to receive(:locate_signed).with('ABC').
          and_raise(ActiveRecord::RecordNotFound)
        wait
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'without attachment' do
      let(:attachment) { nil }

      it 'answers not found' do
        expect_signed_in_as(admin)
        wait
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'without referer' do
      let(:referer) { '' }

      # Not a 404 page in tests: RouteNotFound is raised as it is.
      it 'raises route not found error' do
        expect_signed_in_as(admin)
        expect { wait }.to raise_error(ApplicationController::RouteNotFound)
      end
    end

    context 'with modified referer' do
      let(:referer) { 'http://example.com/attack' }

      # Not a 404 page in tests: RouteNotFound is raised as it is.
      it 'raises route not found error' do
        expect_signed_in_as(admin)
        expect { wait }.to raise_error(ApplicationController::RouteNotFound)
      end
    end
  end

  describe 'GET done' do
    def done
      get done_attachment_mask_path('ABC', referer: referer)
    end

    context 'when attachment is unmasked' do
      let(:attachment) { FactoryBot.build(:body_text, :unmasked, id: 1) }

      it 'redirects to wait action' do
        allow(attachment).to receive(:to_signed_global_id).and_return('ABC')
        done
        expect(response).to redirect_to(
          wait_for_attachment_mask_path('ABC', referer: signed_referer)
        )
      end
    end

    context 'when attachment is masked' do
      it 'shows the download link' do
        done
        expect(response).to have_http_status(:ok)
        page = Nokogiri::HTML(response.body)
        expect(page.at_css('h1.page-band__title').text).
          to eq('Attachment available for download.')
        expect(page.at_css('a.button')['href']).to eq('/referer')
      end

      it 'sets noindex, nofollow header' do
        done
        expect(response.headers['X-Robots-Tag']).to eq 'noindex, nofollow'
      end
    end

    context "when attachment can't be found" do
      it 'answers not found' do
        expect_signed_in_as(admin)
        allow(GlobalID::Locator).to receive(:locate_signed).with('ABC').
          and_raise(ActiveRecord::RecordNotFound)
        done
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'without attachment' do
      let(:attachment) { nil }

      it 'answers not found' do
        expect_signed_in_as(admin)
        done
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'without referer' do
      let(:referer) { '' }

      # Not a 404 page in tests: RouteNotFound is raised as it is.
      it 'raises route not found error' do
        expect_signed_in_as(admin)
        expect { done }.to raise_error(ApplicationController::RouteNotFound)
      end
    end

    context 'with modified referer' do
      let(:referer) { 'http://example.com/attack' }

      # Not a 404 page in tests: RouteNotFound is raised as it is.
      it 'raises route not found error' do
        expect_signed_in_as(admin)
        expect { done }.to raise_error(ApplicationController::RouteNotFound)
      end
    end
  end
end
