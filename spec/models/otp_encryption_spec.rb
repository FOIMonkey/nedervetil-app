require 'spec_helper'

RSpec.describe 'OTP storage' do
  it 'encrypts the new secret with the existing Rails configuration' do
    user = FactoryBot.create(:user, :enable_totp)
    secret = user.otp_secret
    expect(user.reload.otp_secret).to eq(secret)
    expect(user.encrypted_attribute?(:otp_secret)).to eq(true)
    expect(user.validate_and_consume_otp!(ROTP::TOTP.new(secret).now)).
      to eq(true)
    expect(user.reload.validate_and_consume_otp!(ROTP::TOTP.new(secret).now)).
      to eq(false)
  end

  it 'stores recovery codes as irreversible hashes and consumes them once' do
    user = FactoryBot.create(:user, :enable_totp)
    codes = user.generate_otp_backup_codes!
    user.save!
    expect(user.reload.devise_otp_backup_codes).not_to include(*codes)
    expect(user.invalidate_otp_backup_code!(codes.first)).to eq(true)
    expect(user.reload.invalidate_otp_backup_code!(codes.first)).to eq(false)
  end

  it 'refuses plaintext in the new encrypted secret column' do
    user = FactoryBot.create(:user)
    User.connection.execute(
      "UPDATE users SET otp_secret = 'JBSWY3DPEHPK3PXP' WHERE id = #{user.id}"
    )
    expect { user.reload.otp_secret }.
      to raise_error(ActiveRecord::Encryption::Errors::Decryption)
  end
end
