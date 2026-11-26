require 'spec_helper'

RSpec.describe 'request/_attachments' do
  let(:info_request) { FactoryBot.create(:info_request) }
  let(:incoming_message) do
    FactoryBot.create(:incoming_message, info_request: info_request)
  end
  let(:attachment) do
    FactoryBot.create(
      :body_text, :unmasked,
      incoming_message: incoming_message,
      masking_failed_at: Time.zone.now
    )
  end

  def render_view
    render partial: 'request/attachments',
           locals: { incoming_message: incoming_message }
  end

  before do
    main_body_part = FactoryBot.create(
      :body_text, incoming_message: incoming_message
    )
    allow(incoming_message).to receive(:get_attachments_for_display).
      and_return([attachment])
    allow(incoming_message).to receive(:get_main_body_text_part).
      and_return(main_body_part)
    allow(view).to receive(:concealed_prominence?).and_return(false)
    allow(view).to receive(:is_admin?).and_return(false)
    allow(view).to receive(:current_user).and_return(nil)
    assign(:user, nil)
  end

  context 'when masking hit a fault on an attachment' do
    it 'lists the file for the requester as usual, with no note' do
      ability = Ability.new(info_request.user)
      allow(view).to receive(:can?) { |*args| ability.can?(*args) }
      allow(view).to receive(:cannot?) { |*args| ability.cannot?(*args) }

      render_view
      expect(rendered).to have_link('Download')
      expect(rendered).
        to have_no_content('We were not able to process this attachment')
    end
  end
end
