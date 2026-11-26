require 'spec_helper'

RSpec.describe 'Admin raw emails', type: :request do
  # Arrange a fully authenticated admin; production has no test-only bypass.
  before { sign_in FactoryBot.create(:admin_user) }

  def page
    Nokogiri::HTML(response.body)
  end

  describe 'GET show' do
    let(:raw_email) { FactoryBot.create(:incoming_message).raw_email }

    describe 'html version' do
      it 'shows the raw email' do
        get admin_raw_email_path(raw_email)
        expect(response).to be_successful
        expect(page.at_css('h1').text).to eq("Raw email #{raw_email.id}")
      end

      context 'when showing a message with a "From" address in the holding pen' do
        let(:inbound_email) do
          <<-EOF.strip_heredoc
          From: bob@example.uk
          To: #{ invalid_to }
          Subject: Basic Email
          Hello, World
          EOF
        end

        let(:public_body) do
          FactoryBot.create(:public_body, request_email: 'body@example.uk')
        end

        let(:info_request) { FactoryBot.create(:info_request) }

        let(:invalid_to) do
          info_request.incoming_email.sub(info_request.id.to_s, 'invalid')
        end

        let(:incoming_message) do
          incoming_message = FactoryBot.create(
            :plain_incoming_message,
            info_request: InfoRequest.holding_pen_request
          )
          incoming_message.raw_email.data = inbound_email
          incoming_message.raw_email.save!
          incoming_message
        end

        let!(:info_request_event) do
          FactoryBot.create(
            :info_request_event,
            event_type: 'response',
            info_request: InfoRequest.holding_pen_request,
            incoming_message: incoming_message,
            params: { rejected_reason: 'Too dull' }
          )
        end

        def show
          get admin_raw_email_path(incoming_message.raw_email)
          expect(response).to be_successful
        end

        def guesses
          page.css('#guessed-requests details.admin-row-details')
        end

        def guess_for(guessed_request)
          page.at_css("#guessed-requests #info_request_#{guessed_request.id}")
        end

        it 'lists public bodies that match the "From" domain' do
          public_body
          show
          links = page.css('.holding_pen ul.unstyled ' \
                           'a[title="View full details"]')
          expect(links.map { |link| link['href'] }).
            to eq([admin_body_path(public_body)])
        end

        it 'lists guessed requests based on the hash' do
          show
          expect(guesses.size).to eq(1)
          guess = guess_for(info_request)
          expect(guess.css('code').text).to eq('email')
          expect(guess.css('strong').map(&:text)).
            to include(info_request.incoming_email, invalid_to)
          scores = guess.css('tr').to_h do |row|
            row.css('td').map { |cell| cell.text.strip }
          end
          expect(scores).to include('ID Guess Score:' => '0%',
                                    'Idhash Guess Score:' => '100%')
        end

        it 'lists guessed requests based on the message subject' do
          other_request =
            FactoryBot.create(:incoming_message, subject: 'Basic Email').
              info_request
          show
          guess = guess_for(other_request)
          expect(guess.css('code').text).to eq('subject')
          expect(guess.css('p strong').text).to eq('Basic Email')
        end

        it 'gives a reason why the message is in the holding pen' do
          show
          expect(page.at_css('.holding_pen .lead strong').text).
            to eq('Too dull')
        end

        it 'gives a default reason if no reason is given' do
          info_request_event.params = {}
          info_request_event.save!
          show
          expect(page.at_css('.holding_pen .lead strong').text).
            to eq('unknown reason')
        end
      end
    end

    describe 'text version' do
      it 'sends the email as an RFC-822 attachment' do
        get admin_raw_email_path(raw_email, format: 'eml')
        expect(response.media_type).to eq('message/rfc822')
        expect(response.body).to eq(raw_email.data)
      end
    end
  end
end
