require 'spec_helper'

RSpec.describe InfoRequest, '.build_from_attributes' do
  let(:user) { FactoryBot.build(:user) }

  def first_message(message_attributes)
    request = described_class.build_from_attributes(
      { title: 'Bin collections' }, message_attributes, user
    )
    request.outgoing_messages.first
  end

  it 'builds a request whose first message is ready to send' do
    message = first_message(body: 'How many bins?')

    expect(message.info_request.user).to eq(user)
    expect(message).to have_attributes(
      body: 'How many bins?', status: 'ready',
      message_type: 'initial_request', what_doing: 'normal_sort'
    )
  end

  it 'takes the parameters a controller has permitted' do
    permitted = ActionController::Parameters.
      new(body: 'How many bins?', what_doing: 'internal_review').
      permit(:body, :what_doing)

    expect(first_message(permitted)).to have_attributes(
      body: 'How many bins?', what_doing: 'normal_sort'
    )
  end

  it 'refuses parameters a controller has not permitted' do
    unpermitted = ActionController::Parameters.new(body: 'How many bins?')

    expect { first_message(unpermitted) }.
      to raise_error(ActiveModel::ForbiddenAttributesError)
  end
end
