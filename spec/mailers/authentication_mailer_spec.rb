require 'spec_helper'

RSpec.describe AuthenticationMailer do
  let(:user) { FactoryBot.create(:user) }

  it 'uses the canonical site origin and existing automated mail headers' do
    message = described_class.reset_password_instructions(user,
      'invented-reset-token').message
    expect(message.to).to eq([user.email])
    expect(message['Auto-Submitted'].value).to eq('auto-generated')
    expect(message['X-Auto-Response-Suppress'].value).to eq('OOF')
    expect(message['Return-Path'].value).to be_present
    expect(message.body.decoded).
      to include('/profile/change_password/invented-reset-token')
    expect(message.body.decoded).not_to include('jonespassword',
      user.encrypted_password)
  end

  it 'carries only a separate account-bound claim alongside a confirmation token' do
    user.draft_claim_for_confirmation = 'invented-purpose-bound-claim'
    message = described_class.confirmation_instructions(user,
      'invented-confirmation-token').message
    expect(message.body.decoded).to include(
      '/c/invented-confirmation-token?draft_claim=invented-purpose-bound-claim'
    )
    expect(message.body.decoded).to include('need to sign in')
    expect(message.body.decoded).not_to include('jonespassword')
  end
end
