require 'spec_helper'

RSpec.describe SingleUseToken do
  shared_examples 'a single-use token' do
    let(:raw_and_digest) { described_class.new_token }
    let(:raw) { raw_and_digest.first }
    let(:digest) { raw_and_digest.last }
    let(:digest_column) { described_class.token_digest_column }
    let(:used_column) { described_class.token_used_column }
    let!(:record) { make.call(digest, 1.hour.from_now) }

    it 'keeps the digest of a random token, never the token' do
      expect(raw).to match(/\A[0-9a-f]{64}\z/)
      expect(record[digest_column]).to eq(Digest::SHA256.hexdigest(raw))
      expect(described_class.where(digest_column => raw)).to be_empty
    end

    it 'finds the record by its token' do
      expect(described_class.find_by_token(raw)).to eq(record)
    end

    it 'refuses anything new_token could not have made' do
      [nil, 42, '', raw.upcase, raw[0..62], "#{raw}0", "#{raw}\n",
       ['array'], { 'hash' => raw }].each do |bad|
        expect(described_class.find_by_token(bad)).to be_nil
        expect(described_class.digest_token(bad)).to be_nil
      end
    end

    it 'refuses a token in a broken or foreign encoding without raising' do
      [(+"\xFF").force_encoding('UTF-8'),
       (+"#{raw}\xFF").force_encoding('UTF-8'),
       raw.encode('UTF-16LE')].each do |bad|
        expect(described_class.find_by_token(bad)).to be_nil
        expect(described_class.digest_token(bad)).to be_nil
      end
    end

    it 'is live until it is used' do
      expect(record).to be_live
      expect(described_class.live).to include(record)

      record.use!

      expect(record.reload[used_column]).to be_present
      expect(record).not_to be_live
      expect(described_class.live).not_to include(record)
    end

    it 'is not live once it expires, the moment included' do
      travel_to(Time.current.change(usec: 0)) do
        record.update_columns(expires_at: Time.current)
        expect(record.reload).not_to be_live
        expect(described_class.live).not_to include(record)
      end
    end

    it 'keeps the row lock when found through a locked relation' do
      sql = []
      callback = ->(*, payload) { sql << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        described_class.transaction { described_class.lock.find_by_token(raw) }
      end
      expect(sql.grep(/FOR UPDATE/)).not_to be_empty
    end
  end

  let(:user) { FactoryBot.create(:user) }

  describe PendingEmailChange do
    let(:make) do
      ->(digest, expires_at) do
        described_class.create!(user: user, old_email: user.email,
                                new_email: 'new@example.com',
                                credential_state: user.credential_state,
                                token_digest: digest, expires_at: expires_at)
      end
    end

    it_behaves_like 'a single-use token'
  end

  describe AuthenticationEnrolment do
    let(:make) do
      ->(digest, expires_at) do
        described_class.create!(user: user,
                                credential_state: user.credential_state,
                                secret: User.generate_otp_secret,
                                token_digest: digest, expires_at: expires_at)
      end
    end

    it_behaves_like 'a single-use token'
  end

  describe AuthenticationReturn do
    let(:make) do
      ->(digest, expires_at) do
        described_class.create!(path: '/', token_digest: digest,
                                expires_at: expires_at)
      end
    end

    it_behaves_like 'a single-use token'
  end

  describe PendingRequestDraft do
    let(:make) do
      ->(digest, expires_at) do
        described_class.create!(payload: '{}', browser_digest: digest,
                                expires_at: expires_at)
      end
    end

    it_behaves_like 'a single-use token'
  end
end
