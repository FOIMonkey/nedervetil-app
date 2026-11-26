require 'spec_helper'
require 'integration/alaveteli_prominence_dsl'

RSpec.describe 'viewing request page with prominence', local_requests: false do
  include AlaveteliPromienceDsl

  let(:within_session) do
    -> { visit "/request/#{info_request.url_title}" }
  end

  def hidden_request
    page.find_by_id('hidden_request').text
  rescue Capybara::ElementNotFound
    ''
  end

  # Letters sit inside closed <details>; without visible: :all, find would
  # miss them and every be_empty assertion below would pass vacuously.
  def hidden_message
    page.find(:id, "incoming-#{incoming_message.id}", visible: :all).
         find(:css, '.hidden_message', visible: :all).text(:all)
  rescue Capybara::ElementNotFound
    ''
  end

  def hidden_attachment
    page.find(:id, "attachment-#{attachment.id}", visible: :all).
         find(:css, '.hidden_attachment', visible: :all).text(:all)
  rescue Capybara::ElementNotFound
    ''
  end

  # The theme hides .hidden_attachment; requester pages use .attachment__held.
  def expect_file_said_to_be_hidden
    expect(hidden_attachment).to be_empty
    row = page.find(:id, "attachment-#{attachment.id}", visible: :all)
    held = row.find(:css, '.attachment__held', visible: :all)
    expect(held.text(:all).squish).
      to eq('We’ve hidden this file. ' \
            'Please contact us if you have any questions.')
    expect(page.html).not_to include(attachment.display_filename)
  end

  it 'when request is hidden, message and attachment are normal' do
    hide_info_request

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }
    requester_session { expect(page.status_code).to eq(404) }

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to be_empty
      expect(hidden_attachment).to be_empty
    end
  end

  it 'when request is requester_only, message and attachment are normal' do
    hide_info_request('requester_only')

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }

    requester_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          Private: only you and the site’s admins can see it.
        TXT
      )
      expect(hidden_message).to be_empty
      expect(hidden_attachment).to be_empty
    end

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "requester_only".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to be_empty
      expect(hidden_attachment).to be_empty
    end
  end

  it 'when request is requester_only, message is hidden, attachment is normal' do
    hide_info_request('requester_only')
    hide_incoming_message

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }

    requester_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          Private: only you and the site’s admins can see it.
        TXT
      )
      expect(hidden_message).to include(
        <<~TXT.squish
          This message has not been published.
        TXT
      )
      expect(hidden_attachment).to be_empty
    end

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "requester_only".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to include(
        <<~TXT.squish
          This message has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_attachment).to be_empty
    end
  end

  it 'when request and message is hidden, attachment is normal' do
    hide_info_request
    hide_incoming_message

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }
    requester_session { expect(page.status_code).to eq(404) }

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to include(
        <<~TXT.squish
          This message has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_attachment).to be_empty
    end
  end

  it 'when request and attachment are requester_only, message is normal' do
    hide_info_request('requester_only')
    hide_attachment('requester_only')

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }

    requester_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          Private: only you and the site’s admins can see it.
        TXT
      )
      expect(hidden_message).to be_empty
      expect(hidden_attachment).to be_empty
    end

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "requester_only".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to be_empty
      expect(hidden_attachment).to be_empty
    end
  end

  it 'when request is hidden, message is normal, attachment is requester_only' do
    hide_info_request
    hide_attachment('requester_only')

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }
    requester_session { expect(page.status_code).to eq(404) }

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to be_empty
      expect(hidden_attachment).to be_empty
    end
  end

  it 'when request and attachment is requester_only, message is hidden' do
    hide_info_request('requester_only')
    hide_incoming_message
    hide_attachment('requester_only')

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }

    requester_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          Private: only you and the site’s admins can see it.
        TXT
      )
      expect(hidden_message).to include(
        <<~TXT.squish
          This message has not been published.
        TXT
      )
      expect(hidden_attachment).to be_empty
    end

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "requester_only".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to include(
        <<~TXT.squish
          This message has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_attachment).to be_empty
    end
  end

  it 'when request and message are hidden, attachment is requester_only' do
    hide_info_request
    hide_incoming_message
    hide_attachment('requester_only')

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }
    requester_session { expect(page.status_code).to eq(404) }

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to include(
        <<~TXT.squish
          This message has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
    end
  end

  it 'when request is requester_only, message is normal, attachment is hidden' do
    hide_info_request('requester_only')
    hide_attachment

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }

    requester_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          Private: only you and the site’s admins can see it.
        TXT
      )
      expect(hidden_message).to be_empty
      expect_file_said_to_be_hidden
    end

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "requester_only".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to be_empty
      expect(hidden_attachment).to include(
        <<~TXT.squish
          This attachment has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
    end
  end

  it 'when request and attachment are hidden, message is normal' do
    hide_info_request
    hide_attachment

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }
    requester_session { expect(page.status_code).to eq(404) }

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to be_empty
      expect(hidden_attachment).to include(
        <<~TXT.squish
          This attachment has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
    end
  end

  it 'when request is requester_only, message and attachment are hidden' do
    hide_info_request('requester_only')
    hide_incoming_message
    hide_attachment

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }

    requester_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          Private: only you and the site’s admins can see it.
        TXT
      )
      expect(hidden_message).to include(
        <<~TXT.squish
          This message has not been published.
        TXT
      )
      expect(hidden_attachment).to be_empty
    end

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "requester_only".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to include(
        <<~TXT.squish
          This message has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_attachment).to include(
        <<~TXT.squish
          This attachment has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
    end
  end

  it 'when request, message and attachment are hidden' do
    hide_info_request
    hide_incoming_message
    hide_attachment

    guest_session { expect(page.status_code).to eq(404) }
    other_user_session { expect(page.status_code).to eq(404) }
    requester_session { expect(page.status_code).to eq(404) }

    admin_session do
      expect(page.status_code).to eq(200)
      expect(hidden_request).to include(
        <<~TXT.squish
          This request has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_message).to include(
        <<~TXT.squish
          This message has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
      expect(hidden_attachment).to include(
        <<~TXT.squish
          This attachment has prominence "hidden".
          You can only see it because you are logged in as a super user.
        TXT
      )
    end
  end
end
