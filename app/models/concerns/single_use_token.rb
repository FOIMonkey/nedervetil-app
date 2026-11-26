# Expiring single-use secret tokens stored only as SHA-256 digests.
# Override token_digest_column/token_used_column if not using defaults.
module SingleUseToken
  extend ActiveSupport::Concern

  FORMAT = /\A[0-9a-f]{64}\z/

  included do
    class_attribute :token_digest_column, default: :token_digest,
                                          instance_writer: false
    class_attribute :token_used_column, default: :consumed_at,
                                        instance_writer: false

    scope :live, -> {
      where(token_used_column => nil).where('expires_at > ?', Time.current)
    }
  end

  class_methods do
    def new_token
      raw = SecureRandom.hex(32)
      [raw, digest_token(raw)]
    end

    # Check ascii_only? before match? so invalid or non-ASCII encodings
    # return nil instead of raising.
    def digest_token(raw)
      return unless raw.is_a?(String) && raw.ascii_only? && raw.match?(FORMAT)

      Digest::SHA256.hexdigest(raw)
    end

    def find_by_token(raw)
      digest = digest_token(raw)
      find_by(token_digest_column => digest) if digest
    end
  end

  def live?
    self[token_used_column].nil? && expires_at > Time.current
  end

  # Caller must hold any lock required for single-use enforcement.
  def use!
    update!(token_used_column => Time.current)
  end
end
