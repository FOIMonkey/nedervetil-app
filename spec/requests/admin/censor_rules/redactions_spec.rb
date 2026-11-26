require 'spec_helper'

RSpec.describe 'Admin censor rule redactions', type: :request do
  # Arrange a fully authenticated admin; production has no test-only bypass.
  before { sign_in users(:admin_user) }

  describe 'GET #index', feature: :redaction_tracking do
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:rule) { FactoryBot.create(:global_censor_rule, text: 'secret') }

    let(:page) { Nokogiri::HTML(response.body) }

    def index
      get admin_request_censor_rule_redactions_path(info_request, rule)
      expect(response).to be_successful
    end

    def redacted_record_links
      page.css('table tr td:first-child a[title="View full details"]').
        map { |link| link['href'] }
    end

    it 'shows the redactions page for the rule' do
      index
      expect(page.at_css('h1').text).
        to eq("Redactions by CensorRule ##{rule.id}")
    end

    it 'shows the info request' do
      index
      expect(page.css('.breadcrumb a').map { |link| link['href'] }).
        to include(admin_request_path(info_request))
    end

    it 'shows the censor rule' do
      index
      expect(page.at_css('dl dd code').text).to eq('secret')
      expect(page.css('a').map { |link| link['href'] }).
        to include(edit_admin_censor_rule_path(rule))
    end

    it 'lists redactions scoped to the request' do
      om = info_request.outgoing_messages.first
      rule.redactions.create!(redactable: om, redacted_attribute: 'body')

      other_request = FactoryBot.create(:info_request)
      other_om = other_request.outgoing_messages.first
      rule.redactions.create!(redactable: other_om, redacted_attribute: 'body')

      index

      expect(redacted_record_links).
        to eq([edit_admin_outgoing_message_path(om)])
    end

    it 'orders redactions chronologically by the redactable record' do
      om = info_request.outgoing_messages.first
      om.update!(created_at: 2.days.ago)

      im = FactoryBot.create(:incoming_message, info_request: info_request,
                                                created_at: 1.day.ago)

      rule.redactions.create!(redactable: om, redacted_attribute: 'body')
      rule.redactions.create!(redactable: im, redacted_attribute: 'from_name')

      index

      expect(redacted_record_links).to eq(
        [edit_admin_outgoing_message_path(om),
         edit_admin_incoming_message_path(im)]
      )
      expect(page.css('table tr td tt').map(&:text)).to eq(
        %w[body OutgoingMessage from_name IncomingMessage]
      )
    end
  end
end
