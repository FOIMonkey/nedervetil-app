require 'spec_helper'

RSpec.describe 'Summary emails' do
  include_context 'with incoming attention off'
  let(:user) { FactoryBot.create(:pro_user, trusted: true) }

  def authority(name)
    FactoryBot.create(:public_body, name: name, short_name: '')
  end

  def response_notice(body_name, files: 0)
    request = FactoryBot.create(:info_request,
                                user: user,
                                public_body: authority(body_name))
    message = FactoryBot.create(:incoming_message, info_request: request)
    files.times {
      FactoryBot.create(:pdf_attachment, incoming_message: message)
    }
    event = request.log_event('response', incoming_message_id: message.id)
    FactoryBot.create(:daily_notification, user: user,
                                           info_request_event: event)
  end

  def late_notice(body_name)
    request = FactoryBot.create(:info_request,
                                user: user,
                                public_body: authority(body_name))
    event = request.log_event('overdue', {})
    FactoryBot.create(:daily_notification, user: user,
                                           info_request_event: event)
  end

  describe IncomingAttention::Summary do
    it 'names a single reply or a single late authority in the subject' do
      expect(described_class.new(user,
                                 [response_notice('Fife Council')]).subject).
        to eq('Fife Council replied')
      expect(described_class.new(user, [late_notice('Home Office')]).subject).
        to eq('Home Office is late')
      long = 'Northumbria Police and Crime Commissioner'
      expect(described_class.new(user, [response_notice(long)]).subject).
        to eq('1 reply')
    end

    it 'gives subjects and the first line as text a page would escape' do
      first = "Tom & Jerry's <b>"
      one = described_class.new(user, [response_notice(first)])
      expect(one.subject).to eq("#{first} replied")
      expect(one.subject).not_to be_html_safe
      late = described_class.new(user, [late_notice('A <i> & B')])
      expect(late.subject).to eq('A <i> & B is late')
      expect(late.subject).not_to be_html_safe

      two = described_class.new(
        user, [response_notice("Bob's & Co"), response_notice('C & D')]
      )
      expect(two.subject).not_to be_html_safe
      expect(two.preview).to eq("Bob's & Co and C & D replied.")
      expect(two.preview).not_to be_html_safe
    end

    it 'counts replies and late requests, and names them in the first line' do
      rows = [response_notice('Fife Council', files: 2),
              response_notice('Leeds City Council'),
              response_notice('Kent County Council'),
              late_notice('Home Office')]
      summary = described_class.new(user, rows)
      expect(summary.subject).to eq('3 replies · 1 late')
      expect(summary.preview).
        to eq('Fife Council, Leeds City Council and 1 other replied. Home ' \
              'Office is late.')
      fife = summary.needs.find { |row| row.line.start_with?('Fife Council') }
      expect(fife.line).to eq('Fife Council · Replied · 2 files')
      expect(summary.needs.map(&:line)).
        to include(a_string_starting_with('Home Office · Late · due '))
      expect(summary.also).to be_empty
    end
  end

  describe 'the email' do
    it 'renders the summary in the copy deck\'s shape' do
      rows = [response_notice('Fife Council'), late_notice('Home Office')]
      mail = NotificationMailer.daily_summary(user, rows).message
      expect(mail.subject).to eq('1 reply · 1 late')
      lines = mail.body.decoded.lines.map(&:strip).reject(&:empty?)
      expect(lines.first).to eq('Fife Council replied. Home Office is late.')
      expect(lines).
        to include('Needs you',
                   'Fife Council · Replied',
                   'One email a day, only when something changed.')
      expect(lines.last).to match(%r{\AChange emails: http://test.host/profile/emails\z})
      expect(mail.body.decoded).
        not_to include('published',
                       'update the status',
                       "the #{AlaveteliConfiguration.site_name} team")
    end
  end
end
