require 'spec_helper'

RSpec.describe 'request_limits/_body' do
  include_context 'with request limits on'

  let(:refusal) { nil }

  before do
    assign :title, 'Sending limit reached'
    render partial: 'request_limits/body',
           locals: { refusal: refusal, draft: false, message: nil }
  end

  context 'with a genuine refusal' do
    let(:refusal) do
      RequestLimits::Refusal.new(:request, 3, 24.hours, false, 1.hour.from_now)
    end

    it 'keeps the limit reason, retry time and help for raising the limit' do
      expect(rendered).
        to have_content('You’ve sent 3 requests in the last 24 hours.')
      expect(rendered).to have_css('time[datetime]')
      expect(rendered).to have_content('we can raise it for your account')
      expect(rendered).to have_link('Contact us about your limit',
                                    href: help_contact_path)
    end
  end

  context 'without a refusal while enforcement is on' do
    it 'keeps the generic fallback and help for raising the limit' do
      expect(rendered).to have_content(
        'You’ve reached the limit on new requests. Please try again later.'
      )
      expect(rendered).to have_content('we can raise it for your account')
      expect(rendered).to have_link('Contact us about your limit',
                                    href: help_contact_path)
    end
  end
end
