# Per-account request and follow-up rate limits and batch authority caps.
# Sends are logged in RequestLimits::Send inside the creating transaction so
# deletions do not restore quota; see doc/FORK.md for the full request gates.
module RequestLimits
  REQUESTS = { 1.minute => 1, 24.hours => 3, 30.days => 10 }.freeze
  FOLLOWUPS = { 30.days => 25 }.freeze
  FOLLOWUPS_PER_REQUEST = { 5.minutes => 3 }.freeze
  BATCH_AUTHORITIES = 50
  # The longest window, plus a day.
  KEEP = 31.days

  # kind: :request, :followup or :batch_authorities. available_at is
  # nil when waiting won't help (too many authorities in one batch).
  Refusal = Data.define(:kind, :limit, :window, :per_request, :available_at)

  # Raised when a send would go over a limit; carries the Refusal.
  class Exceeded < StandardError
    attr_reader :refusal

    def initialize(refusal)
      @refusal = refusal
      super("#{refusal.kind} limit reached")
    end
  end

  BatchesOff = Class.new(StandardError)

  # Active in production unless ENFORCE_REQUEST_LIMITS is false; elsewhere
  # requires REQUEST_LIMITS=on (or specs setting it) so seeds keep working.
  mattr_accessor :enforced, default: ENV['REQUEST_LIMITS'] == 'on'

  def self.enforced?
    (Rails.env.production? && AlaveteliConfiguration.enforce_request_limits) ||
      enforced
  end

  def self.batch_permission_required?
    Rails.env.production? || enforced
  end

  def self.exempt?(user)
    user.trusted?
  end

  def self.batches_allowed?(user)
    return true unless batch_permission_required?

    user.present? && user.trusted?
  end

  def self.refusal(user, kind, info_request_id: nil)
    return unless enforced? && user && !exempt?(user)

    rules(user, kind, info_request_id).
      filter_map do |scope, window, limit, per_request|
        times = scope.where(created_at: window.ago..).
          order(created_at: :desc).limit(limit).pluck(:created_at)
        if times.size >= limit
          Refusal.new(kind, limit, window, per_request, times.last + window)
        end
      end.max_by(&:available_at)
  end

  def self.batch_authority_limit
    BATCH_AUTHORITIES
  end

  # Applies to every batch, including trusted accounts.
  def self.batch_size_refusal(authorities)
    return if authorities <= BATCH_AUTHORITIES

    Refusal.new(:batch_authorities, BATCH_AUTHORITIES, nil, false, nil)
  end

  def self.record!(user, kind, info_request_id: nil)
    return unless enforced? && user && !user.internal_admin_user?

    ActiveRecord::Base.transaction do
      # Not FOR UPDATE: a new request already holds the foreign key's KEY
      # SHARE lock on this row, and core's request counter updates it, so two
      # at once would deadlock.
      User.where(id: user.id).lock('FOR NO KEY UPDATE').pick(:id)
      refused = refusal(user, kind, info_request_id: info_request_id)
      raise Exceeded, refused if refused

      Send.where(created_at: ...KEEP.ago).delete_all
      Send.create!(user_id: user.id,
                   kind: kind.to_s,
                   info_request_id: info_request_id)
    end
  end

  def self.rules(user, kind, info_request_id)
    mine = Send.where(user_id: user.id, kind: kind.to_s)
    case kind
    when :request
      REQUESTS.map { |window, limit| [mine, window, limit, false] }
    when :followup
      FOLLOWUPS.map { |window, limit| [mine, window, limit, false] } +
        FOLLOWUPS_PER_REQUEST.map do |window, limit|
          [mine.where(info_request_id: info_request_id), window, limit, true]
        end
    end
  end
  private_class_method :rules
end
