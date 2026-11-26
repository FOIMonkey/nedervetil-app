require 'spec_helper'

RSpec.describe "admin/requests/show" do
  before do
    assign :info_request, info_request
  end

  context 'for a reported request' do
    let(:reporter) { FactoryBot.create(:user, name: 'Rita Reporter') }
    let(:info_request) do
      request = FactoryBot.create(:info_request)
      request.set_described_state('successful')
      request.report!('Vexatious', 'Please check this one', reporter)
      request
    end

    it 'offers to revert to the classification before the report' do
      render
      action = revert_report_admin_request_path(info_request)
      expect(rendered).to have_css("#revert_report form[action='#{action}']")
      expect(rendered).to have_button('Revert report')
      expect(rendered).to have_css(
        '#revert_report', text: 'before it was reported (successful)'
      )
    end

    it 'sends the report it shows, so a newer one is not reverted unseen' do
      render
      expect(rendered).to have_field(
        'report_event_id',
        type: 'hidden',
        with: info_request.last_report_event.id.to_s
      )
    end

    it 'shows markup in the message as text' do
      info_request.last_report_event.update!(
        params: info_request.last_report_event.params.merge(
          message: 'See <img src="https://example.com/t.gif"> and ' \
                   '<foi@example.com>'
        )
      )

      render

      expect(rendered).to have_no_css('.admin-report-message img')
      expect(rendered).to have_css('.admin-report-message',
                                   text: '<img src="https://example.com/t.gif">')
      expect(rendered).to have_css('.admin-report-message',
                                   text: '<foi@example.com>')
    end

    it 'shows who reported it, why and their message' do
      render
      expect(rendered).to have_css('#revert_report', text: 'Rita Reporter')
      expect(rendered).to have_css('#revert_report', text: 'Reason: Vexatious')
      expect(rendered).to have_css('#revert_report .admin-report-message',
                                   text: 'Please check this one')
    end

    it 'says nothing about replies when the earlier status covered them' do
      render
      expect(rendered).not_to include('Replies received after that status')
    end

    it 'explains instead of offering it while a reply is waiting' do
      message = FactoryBot.create(:incoming_message, info_request: info_request)
      info_request.log_event('response', incoming_message_id: message.id)
      info_request.update!(awaiting_description: true)

      render

      expect(rendered).to have_no_button('Revert report')
      expect(rendered).to have_css('#revert_report',
                                   text: 'A reply is waiting to be read')
    end
  end

  context 'for a request reported after a reply it then counted classified' do
    let(:info_request) do
      request = FactoryBot.create(:info_request)
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
      request.update!(awaiting_description: true)
      request.report!('Vexatious', 'Please check', FactoryBot.create(:user))
      request
    end

    it 'says the reply stays counted and only the latest takes the status' do
      render
      expect(rendered).to have_css(
        '#revert_report', text: 'before it was reported (waiting_response)'
      )
      expect(rendered).to have_css(
        '#revert_report',
        text: 'Replies received after that status and before the report: 1.'
      )
      expect(rendered).to have_css(
        '#revert_report',
        text: 'Only the latest takes the status waiting_response.'
      )
    end
  end

  context 'for a request that is not reported' do
    let(:info_request) { FactoryBot.create(:info_request) }

    it 'offers no revert' do
      render
      expect(rendered).to have_no_css('#revert_report')
    end
  end

  context 'for a public request' do
    let(:info_request) { FactoryBot.create(:info_request) }

    it 'links to the public request page' do
      render
      expect(rendered).to match(request_url(info_request))
    end
  end

  context 'with a file that went out with parts not masked' do
    let(:info_request) do
      FactoryBot.create(:info_request_with_html_attachment)
    end

    it 'says so in its row' do
      allow_any_instance_of(FoiAttachment).
        to receive(:unmasked_parts).and_return(['the PDF needs a password'])

      render

      expect(rendered).to have_css('.admin-files li', text: 'Parts not masked')
      expect(rendered).to have_css('.admin-files li',
                                   text: 'the PDF needs a password')
    end

    it 'says nothing for a file masked in full' do
      render
      expect(rendered).to have_css('.admin-files li')
      expect(rendered).not_to include('Parts not masked')
    end
  end

  context 'for a redacted request' do
    let(:info_request) do
      request = FactoryBot.create(:info_request)
      FactoryBot.create(:info_request_censor_rule,
                        text: 'information',
                        replacement: '[REDACTED]',
                        censorable: request)
      request.reload
    end

    it 'shows the redacted message in the chronological thread' do
      render
      expect(rendered).to have_css('.admin-thread__item--outgoing blockquote',
                                   text: 'Some [REDACTED] please')
    end

    it 'shows the unredacted message in the outgoing details drawer' do
      render
      ogm = info_request.outgoing_messages.last
      expect(rendered).to have_css("#outgoing_#{ogm.id}",
                                   text: 'Some information please')
    end
  end
end
