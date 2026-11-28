require 'spec_helper'

# Who a request, reply or file is for (Ability::RequesterVisible); the table
# of who sees what, viewer by viewer, is visibility_table_spec.rb.
RSpec.describe Ability::RequesterVisible do
  include DisclosuresHelpers

  let(:request) { FactoryBot.create(:info_request) }
  let(:reply) do
    AttachmentFixtures.deliver(request,
                               [['runs.txt', 'text/plain', "Gritting runs\n"]])
  end
  let(:file) { file_in(reply, 'runs.txt') }

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

  # An allow-list: a value it doesn't name is for admins alone.
  it 'gives admins a prominence it does not name' do
    file
    expect(described_class.of(set(request, 'something_new'))).to eq(:admins)
    expect(described_class.of(set(reply, 'something_new'))).to eq(:admins)
    expect(described_class.of(set(file, 'something_new'))).to eq(:admins)
  end

  it 'gives a reply the least of its own and its request\'s' do
    expect(described_class.of(reply)).to eq(:requester)
    # Only a file has requester_only; a stored one on a reply is unknown.
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

  it 'gives a file the least of its own, its reply\'s and its request\'s' do
    expect(described_class.of(file)).to eq(:requester)
    expect(described_class.of(set(file, 'requester_only'))).to eq(:requester)
    set(file, 'public')
    set(reply, 'hidden')
    expect(described_class.of(file.reload)).to eq(:admins)
    expect(described_class.own(file)).to eq(:requester)
  end

  it 'gives nobody an erased file, or one without its reply or request' do
    expect(described_class.of(nil)).to eq(:nobody)
    expect(described_class.of(FoiAttachment.new(prominence: 'public'))).
      to eq(:nobody)
    file.update_columns(erased_at: Time.current)
    expect(described_class.of(file.reload)).to eq(:nobody)
    expect(described_class.nobody?(file)).to be(true)
  end

  it 'keeps a masking-failed file visible to its requester unless hidden' do
    file.update_columns(masking_failed_at: Time.current)
    expect(described_class.of(file.reload)).to eq(:requester)
    expect(described_class.requester?(file)).to be(true)
    expect(described_class.hidden_by_admin?(file)).to be(false)

    file.update_columns(prominence: 'hidden')
    expect(described_class.of(file.reload)).to eq(:admins)
    expect(described_class.hidden_by_admin?(file)).to be(true)
  end

  it 'gives a document its source\'s level, and admins once its reply moves' do
    document = document_from_attachment(file, by: request.user)
    expect(described_class.of(document)).to eq(:requester)
    expect(described_class.hidden_by_admin?(document)).to be(false)
    reply.update!(info_request: FactoryBot.create(:info_request))
    document.reload
    expect(described_class.of(document)).to eq(:admins)
    expect(described_class.hidden_by_admin?(document)).to be(true)
    reply.destroy
    expect(described_class.of(document.reload)).to eq(:nobody)
  end

  describe 'a spreadsheet still being checked' do
    let(:file) do
      reply = AttachmentFixtures.deliver(
        request,
        [['costs.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          'not read yet']]
      )
      file_in(reply, 'costs.xlsx')
    end

    it 'is for admins until it is read, though nobody hid it' do
      expect(FoiAttachment::SpreadsheetHold.waiting?(file)).to be(true)
      expect(described_class.of(file)).to eq(:admins)
      expect(described_class.hidden_by_admin?(file)).to be(false)
      set(file, 'hidden')
      expect(described_class.hidden_by_admin?(file)).to be(true)
    end
  end

  it 'says the same in SQL as in Ruby, for every request, reply and file ' \
     'prominence' do
    sql = described_class.sql(request: 'info_requests',
                              message: 'incoming_messages',
                              file: 'foi_attachments')
    found = -> do
      InfoRequest.joins(incoming_messages: :foi_attachments).
        where(foi_attachments: { id: file.id }).where(sql).exists?
    end
    states = %w[requester_only hidden].product(
      %w[normal hidden],
      %w[public requester_only hidden unknown erased masking_failed]
    )
    answers = states.to_h do |request_state, reply_state, file_state|
      set(request, request_state)
      set(reply, reply_state)
      prominence =
        %w[erased masking_failed].include?(file_state) ? 'public' : file_state
      file.update_columns(
        prominence: prominence,
        erased_at: (Time.current if file_state == 'erased'),
        masking_failed_at: (Time.current if file_state == 'masking_failed')
      )
      [[request_state, reply_state, file_state],
       [described_class.requester?(file.reload), found.call]]
    end
    expect(answers.reject { |_, (ruby, sql_says)| ruby == sql_says }).
      to be_empty
    expect(answers.count { |_, (ruby, _)| ruby }).to eq(3)
  end

  it 'needs at least one table for SQL' do
    expect { described_class.sql }.to raise_error(ArgumentError)
  end

  it 'has no answer for anything else' do
    expect { described_class.of(User.new) }.to raise_error(ArgumentError)
    expect { described_class.of(AttachmentManagement::Revision.new) }.
      to raise_error(ArgumentError)
  end
end
