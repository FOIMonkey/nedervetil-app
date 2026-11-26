require 'spec_helper'

RSpec.describe 'Read-only holding-pen checks' do
  include ActiveJob::TestHelper

  let(:owner) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }

  before do
    # Permission checks and callbacks must not create or repair the holding pen.
    expect(InfoRequest).not_to receive(:holding_pen_request)
  end

  [nil, 'ordinary_request', 'holding_pen'].each do |title|
    it "checks an unsaved #{title.inspect} title without creating the holding pen" do
      request = InfoRequest.new(url_title: title)
      expect(request.holding_pen_request?(read_only: true)).
        to eq(title == 'holding_pen')
    end
  end

  [false, true].each do |holding|
    context(holding ? 'for the holding pen' : 'for an ordinary request') do
      before do
        info_request.update_column(:url_title, 'holding_pen') if holding
      end

      it 'sets the notification default without looking up another request' do
        info_request.use_notifications = nil
        info_request.send(:set_use_notifications)
        expect(info_request.use_notifications?).to eq(!holding)
      end

      it 'queues document suggestions only for ordinary mail' do
        message = FactoryBot.create(:incoming_message,
                                     info_request: info_request)
        clear_enqueued_jobs
        allow(ActiveRecord).to receive(:after_all_transactions_commit).and_yield
        message.send(:suggest_documents_later)
        if holding
          expect(Disclosures::SuggestJob).not_to have_been_enqueued
        else
          expect(Disclosures::SuggestJob).to have_been_enqueued.with(message.id)
        end
      end

      it 'admits only ordinary mail to attention input' do
        message = FactoryBot.create(:incoming_message,
                                     info_request: info_request)
        expect(IncomingAttention::Input.available?(message)).to eq(!holding)
      end

      it 'creates attention predictions only for ordinary mail' do
        allow(IncomingAttention::Config).to receive(:enabled?).and_return(true)
        message = FactoryBot.create(:incoming_message,
                                     info_request: info_request)
        row = IncomingAttention::Prediction.ensure_for(message)
        expect(row.present?).to eq(!holding)
        expect(
          IncomingAttention::Prediction.exists?(incoming_message: message)
        ).to eq(!holding)
      end

      it 'offers requester deletion only for ordinary requests' do
        deletion = Disclosures::RequestDeletion.new(info_request, owner)
        expect(deletion.offered?).to eq(!holding)
      end

      it 'shows the document panel only for ordinary requests' do
        expect(Ability.new(owner).can?(:see_document_panel, info_request)).
          to eq(!holding)
        admin = FactoryBot.create(:admin_user)
        expect(Ability.new(admin).can?(:see_document_panel, info_request)).
          to eq(!holding)
      end
    end
  end
end
