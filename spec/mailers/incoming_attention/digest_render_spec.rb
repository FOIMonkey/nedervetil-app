require 'spec_helper'

RSpec.describe 'Lean notification summaries' do
  include_context 'with lean attention predictions'
  let(:user) {
    FactoryBot.create(:pro_user, trusted: true)
  }

  def notice(target = nil, route = nil)
    target ||= FactoryBot.create(:info_request, user: user,
                                                use_notifications: false)
    message = lean_response(target, route)
    FactoryBot.create(:daily_notification,
                      user: user,
                      info_request_event: message.response_event)
  end

  def render_summary(rows, enabled: true)
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(enabled)
    shown = enabled ? IncomingAttention::Digest.presentation(user, rows) : nil
    NotificationMailer.daily_summary(user, rows, shown).message.body.decoded
  end

  it 'renders exact current split response links without excerpts or implementation details' do
    attention = notice(nil, 'REVIEW')
    routine = notice(nil, 'SKIP')
    body = render_summary([attention, routine])
    expect(body).to include('Needs you', 'Also')
    [attention, routine].each do |row|
      message = row.info_request_event.incoming_message
      expect(body).
        to include(NotificationMailer.new.new_response_url(message.info_request,
                                                           message))
    end
    expect(body).
      not_to include('input_fingerprint',
                     'coverage_verified',
                     'SnapshotChanged')
  end

  it 'shows existing human classification separately, as a plain reply' do
    row = notice(nil, 'REVIEW')
    row.info_request_event.update_columns(last_described_at: Time.current)
    body = render_summary([row])
    expect(body).to include('Also', '· Replied')
    expect(body).not_to include('Needs you', 'Other reply to review')
    shown = IncomingAttention::Digest.presentation(user, [row])
    expect(shown.sections[:needs_attention]).to be_empty
    expect(shown.sections[:already_reviewed]).not_to be_empty
  end

  it 'retains batch grouping and direct request grouping in a mixed summary' do
    batch = FactoryBot.create(:info_request_batch, :sent, user: user,
                                                          public_body_count: 2)
    batch_notice = notice(batch.info_requests.first, 'SKIP')
    direct = notice(nil, 'REVIEW')
    body = render_summary([batch_notice, direct])
    expect(body).
      to include(batch.title, direct.info_request_event.info_request.title)
  end

  it 'preserves nonresponse notices in the other section' do
    target = FactoryBot.create(:info_request, user: user)
    event = FactoryBot.create(:info_request_event, info_request: target,
                                                   event_type: 'overdue')
    overdue = FactoryBot.create(:daily_notification, user: user,
                                                     info_request_event: event)
    body = render_summary([overdue, notice(nil, 'SKIP')])
    expect(body).to include('Needs you', 'Also', target.title, 'Late · due')
  end

  [false, true].each do |enabled|
    it "rejects a stale reassigned request in summary with enabled=#{enabled}" do
      row = notice
      target = row.info_request_event.info_request
      target.update_columns(user_id: FactoryBot.create(:user).id,
                            prominence: 'requester_only')
      expect { render_summary([row], enabled: enabled) }.to raise_error(IncomingAttention::Digest::SnapshotChanged)
    end

    it "rejects a message moved to another request with enabled=#{enabled}" do
      row = notice
      other = FactoryBot.create(:info_request, user: FactoryBot.create(:user),
                                               prominence: 'requester_only')
      row.info_request_event.incoming_message.
        update_columns(info_request_id: other.id)
      expect { render_summary([row], enabled: enabled) }.to raise_error(IncomingAttention::Digest::SnapshotChanged)
    end

    it "guards instant and direct response rendering with enabled=#{enabled}" do
      row = notice
      row.info_request_event.info_request.
        update_columns(user_id: FactoryBot.create(:user).id)
      allow(IncomingAttention::Config).to receive(:enabled?).and_return(enabled)
      expect { NotificationMailer.instant_notification(row).message }.
        to raise_error(IncomingAttention::Digest::SnapshotChanged)
      expect { NotificationMailer.response_notification(row).message }.
        to raise_error(IncomingAttention::Digest::SnapshotChanged)
    end

    it "omits reassigned private batch targets from headers with enabled=#{enabled}" do
      batch = FactoryBot.create(:info_request_batch,
                                :sent,
                                user: user,
                                public_body_count: 2)
      visible, private_target = batch.info_requests.order(:id).to_a
      private_target.update_columns(user_id: FactoryBot.create(:user).id,
                                    prominence: 'requester_only')
      body = render_summary([notice(visible, 'REVIEW')], enabled: enabled)
      expect(body).to include(visible.public_body.name)
      expect(body).not_to include(private_target.public_body.name)
    end
  end

  it 'groups a newly owned child as a direct request without its former private batch title' do
    other_owner = FactoryBot.create(:pro_user, trusted: true)
    batch = FactoryBot.create(:info_request_batch, :sent, user: other_owner,
                                                          public_body_count: 2)
    target = batch.info_requests.first
    target.update_columns(user_id: user.id, prominence: 'requester_only')
    body = render_summary([notice(target, 'REVIEW')])
    expect(body).to include(target.title)
    # The batch and child share their original title; check the group itself.
    shown = IncomingAttention::Digest.presentation(user, [Notification.where(
      user: user
    ).last])
    expect(shown.sections[:needs_attention].keys).to all(be_a(InfoRequest))
  end

  it 'rejects a saved presentation after source identity changes before rendering' do
    row = notice(nil, 'REVIEW')
    shown = IncomingAttention::Digest.presentation(user, [row])
    row.info_request_event.incoming_message.update_columns(prominence: 'hidden')
    expect { NotificationMailer.daily_summary(user, [row], shown).message }.
      to raise_error(IncomingAttention::Digest::SnapshotChanged)
  end
end
