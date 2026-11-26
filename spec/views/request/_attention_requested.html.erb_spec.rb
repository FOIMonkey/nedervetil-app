require 'spec_helper'

RSpec.describe 'request/attention_requested' do
  def render_view
    render partial: self.class.top_level_description,
           locals: { info_request: info_request }
  end

  context 'when the request is hidden' do
    let(:info_request) { FactoryBot.build(:info_request, prominence: 'hidden') }

    before do
      allow(view).to receive(:current_user)
      allow(controller).to receive(:current_ability).
        and_return(Ability.new(nil))
    end

    it 'shows the request is hidden' do
      render_view
      expect(rendered).to include 'This request has not been published'
    end
  end

  context 'when the request is requester_only' do
    let(:info_request) do
      FactoryBot.build(:info_request, prominence: 'requester_only')
    end

    before do
      allow(view).to receive(:current_user).and_return(info_request.user)
      allow(controller).to receive(:current_ability).
        and_return(Ability.new(info_request.user))
    end

    it 'shows the request is requester_only' do
      render_view
      expect(rendered).to include 'only you and the site’s admins can see it'
    end
  end
end
