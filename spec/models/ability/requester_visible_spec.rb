require 'spec_helper'

RSpec.describe Ability::RequesterVisible do
  let(:request) { FactoryBot.create(:info_request) }
  let(:reply) { FactoryBot.create(:incoming_message, info_request: request) }
  let(:file) do
    FactoryBot.create(:foi_attachment, incoming_message: reply,
                                       prominence: 'public')
  end

  def set(record, prominence)
    record.update_columns(prominence: prominence)
    record.reload
  end

  it 'orders nobody below admins below requester' do
    expect(described_class::ORDER).to eq(%i[nobody admins requester])
    expect(described_class.least(:requester, :admins)).to eq(:admins)
    expect(described_class.least(:admins, :nobody, :requester)).to eq(:nobody)
    expect(described_class.least(:requester)).to eq(:requester)
  end

  it 'gives a request to its requester, or to admins when hidden' do
    expect(described_class.of(request)).to eq(:requester)
    expect(described_class.of(set(request, 'hidden'))).to eq(:admins)
  end

  it 'fails closed to admins for unknown prominence values' do
    file
    expect(described_class.of(set(request, 'something_new'))).to eq(:admins)
    expect(described_class.of(set(reply, 'something_new'))).to eq(:admins)
    expect(described_class.of(set(file, 'something_new'))).to eq(:admins)
  end

  it 'gives a reply the least of its own and its request visibility' do
    expect(described_class.of(reply)).to eq(:requester)
    expect(described_class.of(set(reply, 'requester_only'))).to eq(:admins)
    expect(described_class.of(set(reply, 'hidden'))).to eq(:admins)
    set(reply, 'normal')
    set(request, 'hidden')
    expect(described_class.of(reply.reload)).to eq(:admins)
    expect(described_class.own(reply)).to eq(:requester)
  end

  it 'treats an outgoing message as a reply' do
    message = request.outgoing_messages.first
    expect(described_class.of(message)).to eq(:requester)
    expect(described_class.of(set(message, 'hidden'))).to eq(:admins)
  end

  it 'gives a file the least of its own, its reply and its request' do
    expect(described_class.of(file)).to eq(:requester)
    expect(described_class.of(set(file, 'requester_only'))).to eq(:requester)
    set(file, 'public')
    set(reply, 'hidden')
    expect(described_class.of(file.reload)).to eq(:admins)
    expect(described_class.own(file)).to eq(:requester)
  end

  it 'gives nobody an erased file or one without a reply or request' do
    expect(described_class.of(nil)).to eq(:nobody)
    expect(described_class.of(FoiAttachment.new(prominence: 'public'))).
      to eq(:nobody)
    file.update_columns(erased_at: Time.current)
    expect(described_class.of(file.reload)).to eq(:nobody)
    expect(described_class.nobody?(file)).to be(true)
  end

  it 'matches SQL visibility across request, reply and file prominences' do
    sql = described_class.sql(request: 'info_requests',
                              message: 'incoming_messages',
                              file: 'foi_attachments')
    found = lambda do
      InfoRequest.joins(incoming_messages: :foi_attachments).
        where(foi_attachments: { id: file.id }).where(sql).exists?
    end
    states = %w[requester_only hidden].product(
      %w[normal hidden],
      %w[public requester_only hidden unknown erased]
    )
    answers = states.to_h do |request_state, reply_state, file_state|
      set(request, request_state)
      set(reply, reply_state)
      prominence = file_state == 'erased' ? 'public' : file_state
      file.update_columns(
        prominence: prominence,
        erased_at: (Time.current if file_state == 'erased')
      )
      [[request_state, reply_state, file_state],
       [described_class.requester?(file.reload), found.call]]
    end
    expect(answers.reject { |_, (ruby, sql_says)| ruby == sql_says }).
      to be_empty
    expect(answers.count { |_, (ruby, _)| ruby }).to eq(2)
  end

  it 'requires at least one table for SQL' do
    expect { described_class.sql }.to raise_error(ArgumentError)
  end

  it 'raises for unsupported record types' do
    expect { described_class.of(User.new) }.to raise_error(ArgumentError)
  end
end
