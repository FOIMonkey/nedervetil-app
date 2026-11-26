require 'spec_helper'

RSpec.describe 'Notification delivery selection', feature: :alaveteli_pro do
  include_context 'with incoming attention off'

  let(:event) { FactoryBot.create(:response_event) }
  let(:user) { event.info_request.user }

  it 'uses the daily summary when the account has not opted into instant mail' do
    expect(IncomingAttention::InstantEmails).not_to be_on(user)
    expect(user.notification_frequency).to eq(Notification::DAILY)

    notification = user.notify(event)
    expect(notification).to be_persisted
    expect(notification).to be_daily
  end

  it 'uses instant mail when the account opts in' do
    IncomingAttention::InstantEmails.set!(user, true)
    expect(user.notification_frequency).to eq(Notification::INSTANTLY)

    notification = user.notify(event)
    expect(notification).to be_persisted
    expect(notification).to be_instantly
  end

  it 'refuses to create a notification if the account setting cannot be read' do
    # Fail the storage lookup itself; a nil/false fallback would turn this
    # into a notification even though the account's choice is unknown.
    allow(IncomingAttention::InstantEmails).to receive(:exists?).
      with(user_id: user.id).and_raise(ActiveRecord::ConnectionNotEstablished)
    before_count = Notification.count

    expect { user.notify(event) }.
      to raise_error(ActiveRecord::ConnectionNotEstablished)
    expect(Notification.count).to eq(before_count)
  end
end
