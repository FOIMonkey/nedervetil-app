require 'spec_helper'

RSpec.describe 'The requester’s own request page' do
  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)
  let(:user) { FactoryBot.create(:pro_user) }
  let(:start) { Time.zone.parse('2026-09-07 10:00') }

  def request_sent
    travel_to(start) { FactoryBot.create(:info_request, user: user) }
  end

  def reply(request, state = nil, at: start + 7.days)
    travel_to(at) do
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
      request.reload.set_described_state(state) if state
      message
    end
  end

  def response_event(request)
    request.reload.info_request_events.find_by(event_type: 'response')
  end

  describe 'the page' do
    it 'gives the requester the band, the next step and what happened, and everyone else core’s page' do
      request = request_sent
      reply(request, 'partially_successful')
      travel_to(start + 10.days) { sign_in(user) }
      travel_to(start + 10.days) { get "/request/#{request.url_title}" }
      page = Nokogiri::HTML(response.body)
      expect(page.at_css('.request-band__crumb').text.squish).
        to eq('Home / Needs you')
      # Coming up has the review date: the band doesn't say it a third time.
      expect(page.at_css('.deadline-track')).to be_nil
      expect(page.at_css('.request-feed--next .feed__title').text.squish).
        to eq('Last day to ask for a review')
      expect(page.at_css('.receipt h2').text.squish).
        to start_with("#{request.public_body.short_name} replied on time · ")
      expect(page.at_css('.receipt__got').text).
        to eq('You got some of it.')
      expect(page.css('.receipt__acts a').find { |link|
        link.text == 'Ask for review'
      }['href']).
        to include('internal_review=1')
      expect(page.css('.feed__title').map(&:text)).
        to include('Request sent', a_string_starting_with('Reply from '))
      expect(page.css('.feed__meta').map(&:text)).
        to include(a_string_including('You got some of it'))
      expect(page.css('.feed__month')).to be_empty
      expect(page.at_css('.request-foot').text).
        to include('Private: only you and the site’s admins can see it.')
      expect(page.at_css('.request-status')).to be_nil

      reset!
      sign_in(FactoryBot.create(:admin_user))
      get "/request/#{request.url_title}"
      page = Nokogiri::HTML(response.body)
      expect(page.at_css('.request-band')).to be_nil
      expect(page.at_css('.request-status')).to be_present
    end

    it 'renders each letter once, in the feed, newest first' do
      request = request_sent
      message = reply(request, 'partially_successful')
      travel_to(start + 10.days) { sign_in(user) }
      travel_to(start + 10.days) { get "/request/#{request.url_title}" }
      page = Nokogiri::HTML(response.body)
      expect(page.css("#incoming_#{message.id}, #incoming-#{message.id}").size).
        to eq(1)
      expect(page.css('.correspondence_text').size).to eq(2)
      titles = page.css('.feed__title').map(&:text)
      expect(titles.index('Request sent')).
        to be > titles.index { |title| title.start_with?('Reply from ') }
      expect(page.at_css('#letters')).to be_nil
      expect(page.at_css('.feed__dates #deadlines')).to be_present
    end

    it 'keeps a signature out of the quote at the top' do
      request = request_sent
      travel_to(start + 7.days) do
        AttachmentFixtures.deliver(
          request, [],
          text: "Dear Sir,\n\nHere is our answer.\n\nYours sincerely,\n\n" \
                "Jane Example\nInformation Rights\n"
        )
      end
      travel_to(start + 10.days) { sign_in(user) }
      travel_to(start + 10.days) { get "/request/#{request.url_title}" }
      expect(Nokogiri::HTML(response.body).
             at_css('.receipt__said blockquote').text.squish).
        to eq('“Here is our answer.”')
    end

    it 'opens no row by itself, and says which are new' do
      request = request_sent
      first = reply(request)
      reply(request, 'partially_successful', at: start + 8.days)
      allow(Deadlines::Overview).
        to receive(:attention_messages).and_return([first])
      travel_to(start + 10.days) { sign_in(user) }
      travel_to(start + 10.days) { get "/request/#{request.url_title}" }
      page = Nokogiri::HTML(response.body)
      row = page.at_css("#reply-#{first.id}")
      expect(row.key?('open')).to be(false)
      expect(row.at_css('.feed__new').text).to eq('New')
    end

    it 'says quietly who it waits for when there is nothing to do' do
      request = request_sent
      travel_to(start + 2.days) { sign_in(user) }
      travel_to(start + 2.days) { get "/request/#{request.url_title}" }
      page = Nokogiri::HTML(response.body)
      step = page.at_css('.next-step--quiet')
      expect(step.at_css('h2').text).
        to eq("Waiting for #{request.public_body.name}")
      expect(step.at_css('p').text).to start_with('Reply due ')
      expect(step.css('a').map(&:text)).to eq(['Send a followup'])
      expect(page.css('.request-foot a').map(&:text)).
        not_to include('Send a followup')
      expect(page.at_css('.request-band__crumb b').text).to eq('Coming up')
    end

    it 'keeps the history in the order a reader wants, with one heading level at a time' do
      request = request_sent
      message = reply(request, 'partially_successful')
      travel_to(start + 10.days) { sign_in(user) }
      travel_to(start + 10.days) { get "/request/#{request.url_title}" }
      page = Nokogiri::HTML(response.body)
      headings = page.
                 css('.page-band h1, .requester-page h2, .requester-page h3').
                 reject { |heading| heading.ancestors('details').any? }.
                 map { |heading| [heading.name, heading.text.strip] }
      expect(headings.map(&:first)).to eq(%w[h1 h2 h2 h2])
      expect(headings.map(&:last)).
        to include(
          a_string_starting_with("#{request.public_body.short_name} replied"),
          'Coming up',
          'What’s happened'
        )
      row = page.at_css("#reply-#{message.id}")
      expect(row.key?('open')).to be(false)
      summary = row.at_css('summary')
      expect(summary['aria-label']).
        to eq(row.at_css('.feed__title').text.squish)
      described = summary['aria-describedby'].split.map do |id|
        page.at_css("##{id}")&.text.to_s.squish
      end
      expect(described.first).to eq(row.at_css('.feed__date').text.squish)
      expect(described).to all(be_present)
      expect(row.at_css('summary .feed__closed').text).to eq('Read')
      expect(page.css('.request-foot a').map(&:text)).
        not_to include('Write a reply', 'Send a followup')
    end

    it 'lists each file once: the latest reply’s at the top, an older reply’s in its row' do
      request = request_sent
      older = travel_to(start + 2.days) do
        AttachmentFixtures.deliver(request,
                                   [['first.csv', 'text/csv', "a,b\n"]],
                                   text: 'First reply.')
      end
      latest = travel_to(start + 5.days) do
        AttachmentFixtures.deliver(request,
                                   [['second.csv', 'text/csv', "a,b\n"]],
                                   text: 'Second reply.')
      end
      travel_to(start + 6.days) { sign_in(user) }
      travel_to(start + 6.days) { get "/request/#{request.url_title}" }
      page = Nokogiri::HTML(response.body)
      expect(page.at_css('.attachments__header')).to be_nil
      expect(page.css('.receipt .attachment__name').map { |n| n.text.strip }).
        to include('second.csv')
      expect(page.css("#reply-#{latest.id} .attachment__name")).to be_empty
      expect(page.css("#reply-#{older.id} .attachment__name").
             map { |n| n.text.strip }).
        to include('first.csv')
      expect(page.css('.attachment').map { |file| file['id'] }.uniq.size).
        to eq(page.css('.attachment').size)
    end

    it 'puts a notice directly under the band, not above it' do
      request = request_sent
      travel_to(start + 2.days) { sign_in(user) }
      travel_to(start + 2.days) do
        post "/deadlines/#{request.id}/response",
             params: { due_on: (start + 40.days).to_date.iso8601,
                       reason: 'other' }
        get "/request/#{request.url_title}"
      end
      page = Nokogiri::HTML(response.body)
      expect(page.at_css('.page-band + .band-flash #notice').text).
        to include('Due date changed')
    end

    def requester_page(request)
      travel_to(start + 10.days) { sign_in(user) }
      travel_to(start + 10.days) { get "/request/#{request.url_title}" }
      Nokogiri::HTML(response.body)
    end

    # Only an admin hides a whole message, so saying why can't give away the
    # result of a check.
    describe 'a letter hidden from the requester' do
      it 'says a reply is hidden and why, with nothing to open and nothing else of it' do
        request = request_sent
        message = reply(request, 'partially_successful')
        message.update!(prominence: 'hidden',
                        prominence_reason: 'Sent here by mistake.')
        row = requester_page(request).at_css("#incoming-#{message.id}")
        expect(row.ancestors('details')).to be_empty
        expect(row.at_css('.feed__hidden .hidden_message')).to be_present
        expect(row.text.squish).to eq(<<~TXT.squish)
          14 Sep Reply hidden This message has not been published.
          Sent here by mistake. Please contact us if you have any questions.
        TXT
      end

      it 'keeps the words of a hidden reply off the page' do
        request = request_sent
        message = reply(request)
        requester_page(request)
        expect(response.body).to include('hereisthetext')
        message.update!(prominence: 'hidden')
        requester_page(request)
        expect(response.body).not_to include('hereisthetext')
      end

      it 'says which of their own letters is hidden, and not what it said' do
        request = request_sent
        letter = request.outgoing_messages.first
        requester_page(request)
        expect(response.body).to include(letter.body)
        letter.update!(prominence: 'hidden',
                       prominence_reason: 'It has a home address in it.')
        row = requester_page(request).at_css("#outgoing-#{letter.id}")
        expect(row.ancestors('details')).to be_empty
        expect(row.text.squish).to eq(<<~TXT.squish)
          7 Sep Request sent You to #{request.public_body.name}
          This message has not been published. It has a home address in it.
          Please contact us if you have any questions.
        TXT
        expect(response.body).not_to include(letter.body)
      end

      it 'still gives them a way to write, that isn’t to whoever sent it' do
        request = request_sent
        reply(request).update!(prominence: 'hidden')
        link = requester_page(request).at_css('a.next-step__minor')
        expect(link.text).to eq('Send a followup')
        expect(link['href']).to eq(
          new_request_followup_path(request.url_title, anchor: 'followup')
        )
      end
    end

    # A reply can mention a file that isn't there, so the page says one is
    # hidden. Not which or why: that can be what a check found.
    describe 'a file hidden from the requester' do
      let(:reason) { 'It has staff names in it.' }
      let(:notice) do
        'We’ve hidden this file. Please contact us if you have any questions.'
      end

      def reply_with_hidden_file(request)
        message = travel_to(start + 7.days) do
          AttachmentFixtures.deliver(
            request,
            [['Routes.csv', 'text/csv', "route,road\n1,A1\n"],
             ['Staffnames.csv', 'text/csv', "name\nA Person\n"]]
          )
        end
        part = message.get_attachments_for_display.
               find { |file| file.display_filename == 'Staffnames.csv' }
        FoiAttachment.find(part.id).tap do |hidden|
          hidden.update!(prominence: 'hidden', prominence_reason: reason)
        end
      end

      it 'says a file is hidden, and not which or why' do
        request = request_sent
        hidden = reply_with_hidden_file(request)
        page = requester_page(request)
        row = page.at_css("#attachment-#{hidden.id}")
        # The theme hides .hidden_attachment.
        expect(row.at_css('.attachment__held').text.squish).to eq(notice)
        expect(row.at_css('.hidden_attachment')).to be_nil
        expect(row.text.squish).to eq(notice)
        expect(row.css('a').map(&:text)).to eq(['contact us'])
        expect(page.at_css('.attachment__name').text).to include('Routes.csv')
        expect(page.at_css('.feed__files').text).
          to include('2 files, listed above')
        expect(response.body).not_to include(hidden.display_filename, reason)
      end

      it 'says so once, in the row of a reply that isn’t the latest, and counts it' do
        request = request_sent
        hidden = reply_with_hidden_file(request)
        reply(request, at: start + 8.days)
        page = requester_page(request)
        expect(page.css("#attachment-#{hidden.id}").size).to eq(1)
        letter = page.at_css("details#reply-#{hidden.incoming_message_id}")
        expect(letter.at_css("#attachment-#{hidden.id}").text.squish).
          to eq(notice)
        expect(letter.at_css('.feed__meta').text).to include('2 files')
        expect(response.body).not_to include(hidden.display_filename, reason)
      end

      it 'doesn’t say why at the file’s own address or in the download' do
        request = request_sent
        hidden = reply_with_hidden_file(request)
        sign_in(user)
        get "/request/#{request.url_title}" \
            "/response/#{hidden.incoming_message_id}" \
            "/attach/#{hidden.url_part_number}/#{hidden.display_filename}"
        expect(response).to have_http_status(:see_other)
        expect(response.headers['Location']).
          not_to include(reason, hidden.display_filename)
        follow_redirect!
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(reason, hidden.display_filename)

        if defined?(RegulatorPack)
          token = RegulatorPack.new(request, user: user).build!
          get download_regulator_pack_path(token: token)
          expect(response).to have_http_status(:ok)
          zip = Zip::File.open_buffer(StringIO.new(response.body))
          text = zip.find_entry('correspondence.txt').get_input_stream.read
          expect(text).to include('This attachment has not been published.')
          expect(text).not_to include(reason, hidden.display_filename)
        end
      ensure
        FileUtils.rm_rf(RegulatorPack.storage_dir) if defined?(RegulatorPack)
      end

      it 'still tells an admin why' do
        request = request_sent
        reply_with_hidden_file(request)
        sign_in(FactoryBot.create(:admin_user))
        get "/request/#{request.url_title}"
        expect(response.body).to include(reason)
      end

      it 'says so when it’s the text of the reply that’s hidden' do
        request = request_sent
        message = reply(request)
        FoiAttachment.find(message.get_main_body_text_part.id).
          update!(prominence: 'hidden', prominence_reason: reason)
        page = requester_page(request)
        expect(page.at_css('.attachment__held').text.squish).to eq(
          'We’ve hidden the text of this reply. ' \
          'Please contact us if you have any questions.'
        )
        expect(response.body).not_to include('hereisthetext', reason)
      end
    end
  end
end
