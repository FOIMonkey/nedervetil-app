require 'spec_helper'

RSpec.describe ProminenceHelper do
  include ProminenceHelper

  let(:prominence) { nil }
  let(:prominence_reason) { nil }
  let(:current_user) { nil }

  let(:requester) { FactoryBot.build(:user) }

  # A request is requester_only or hidden, so one whose reply or file is
  # normal is requester_only.
  let(:info_request) do
    FactoryBot.build(
      :info_request,
      user: requester,
      prominence: prominence == 'normal' ? 'requester_only' : prominence,
      prominence_reason: prominence_reason
    )
  end

  let(:incoming_message) do
    FactoryBot.build(
      :incoming_message,
      info_request: info_request,
      prominence: prominence,
      prominence_reason: prominence_reason
    )
  end

  let(:object) { incoming_message }

  # As in a view: the viewer's Ability.
  def can?(*args)
    Ability.new(current_user).can?(*args)
  end

  describe '#concealed_prominence?' do
    subject { concealed_prominence?(prominenceable) }

    context 'object with normal prominence' do
      let(:prominence) { 'normal' }
      let(:prominenceable) { incoming_message }
      it { is_expected.to eq false }
    end

    context 'object with hidden prominence' do
      let(:prominence) { 'hidden' }
      let(:prominenceable) { info_request }
      it { is_expected.to eq true }
    end

    context 'object with requester_only prominence' do
      let(:prominence) { 'requester_only' }
      let(:prominenceable) { info_request }
      it { is_expected.to eq true }
    end

    context 'non-prominenceable object' do
      let(:prominenceable) { nil }
      it { is_expected.to eq false }
    end
  end

  describe '#render_prominence' do
    subject { render_prominence(object) }

    let(:request) { OpenStruct.new(fullpath: '/') }

    let(:reason) do
      'Requests on this site are private until they are published.'
    end

    let(:sign_in_message) do
      'If you are the requester, then you may ' \
      '<a href="/profile/sign_in?r=%2F">sign in</a> to view the message.'
    end

    let(:sign_in_request) do
      'If you are the requester, then you may ' \
      '<a href="/profile/sign_in?r=%2F">sign in</a> to view the request.'
    end

    let(:contact_us) do
      'Please <a href="/help/contact">contact us</a> if you have any ' \
      'questions.'
    end

    context 'as text format' do
      subject { render_prominence(object, format: :text) }

      let(:object) { info_request }
      let(:prominence) { 'requester_only' }
      let(:current_user) { nil }

      it 'excludes links' do
        is_expected.to_not include sign_in_request
        is_expected.to_not include contact_us
      end
    end

    context 'request with hidden prominence' do
      let(:object) { info_request }
      let(:prominence) { 'hidden' }
      let(:current_user) { nil }

      it 'returns expected message' do
        is_expected.to include 'This request has not been published.'
        is_expected.to include reason
        is_expected.to_not include sign_in_request
        is_expected.to include contact_us
      end
    end

    context 'request with hidden prominence as requester' do
      let(:object) { info_request }
      let(:prominence) { 'hidden' }
      let(:current_user) { requester }

      it 'returns expected message' do
        is_expected.to include 'This request has not been published.'
        is_expected.to include reason
        is_expected.to_not include sign_in_request
        is_expected.to include contact_us
      end
    end

    context 'request with hidden prominence as admin' do
      let(:object) { info_request }
      let(:prominence) { 'hidden' }
      let(:current_user) { FactoryBot.create(:admin_user) }

      it 'returns expected message' do
        is_expected.to eq <<~TXT.squish
          This request has prominence "hidden".

          You can only see it because you are logged in as a super user.
        TXT
      end
    end

    context 'request with hidden prominence and reason as admin' do
      let(:object) { info_request }
      let(:prominence) { 'hidden' }
      let(:prominence_reason) { 'Spam.' }
      let(:current_user) { FactoryBot.create(:admin_user) }

      it 'returns expected message' do
        is_expected.to eq <<~TXT.squish
          This request has prominence "hidden". Spam.

          You can only see it because you are logged in as a super user.
        TXT
      end
    end

    context 'request with requester_only prominence' do
      let(:object) { info_request }
      let(:prominence) { 'requester_only' }
      let(:current_user) { nil }

      it 'returns expected message' do
        is_expected.to include 'This request has not been published.'
        is_expected.to include reason
        is_expected.to include sign_in_request
        is_expected.to include contact_us
      end
    end

    context 'request with requester_only prominence as requester' do
      let(:object) { info_request }
      let(:prominence) { 'requester_only' }
      let(:current_user) { requester }

      it 'returns expected message' do
        is_expected.to include <<~TXT.squish
          Private: only you and the site’s admins can see it.
        TXT
        is_expected.to include reason
        is_expected.to_not include sign_in_request
        is_expected.to include contact_us
      end
    end

    context 'request with requester_only prominence as admin' do
      let(:object) { info_request }
      let(:prominence) { 'requester_only' }
      let(:current_user) { FactoryBot.create(:admin_user) }

      it 'returns expected message' do
        is_expected.to eq <<~TXT.squish
          This request has prominence "requester_only".

          You can only see it because you are logged in as a super user.
        TXT
      end
    end

    context 'message with normal prominence' do
      let(:object) { incoming_message }
      let(:prominence) { 'normal' }
      it { is_expected.to be_nil }
    end

    context 'message with hidden prominence' do
      let(:object) { incoming_message }
      let(:prominence) { 'hidden' }
      let(:current_user) { nil }

      it 'returns expected message' do
        is_expected.to include 'This message has not been published.'
        is_expected.to include reason
        is_expected.to_not include sign_in_message
        is_expected.to include contact_us
      end
    end

    context 'message with hidden prominence as requester' do
      let(:object) { incoming_message }
      let(:prominence) { 'hidden' }
      let(:current_user) { requester }

      it 'returns expected message' do
        is_expected.to include 'This message has not been published.'
        is_expected.to include reason
        is_expected.to_not include sign_in_message
        is_expected.to include contact_us
      end
    end

    context 'message with hidden prominence as admin' do
      let(:object) { incoming_message }
      let(:prominence) { 'hidden' }
      let(:current_user) { FactoryBot.create(:admin_user) }

      it 'returns expected message' do
        is_expected.to eq <<~TXT.squish
          This message has prominence "hidden".

          You can only see it because you are logged in as a super user.
        TXT
      end
    end
  end
end
