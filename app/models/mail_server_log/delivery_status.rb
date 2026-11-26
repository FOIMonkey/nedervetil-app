# Comparable value object representing an outgoing email's delivery state
# (:unknown, :failed, :sent or :delivered) with translated display strings.
class MailServerLog::DeliveryStatus
  include Comparable

  def initialize(status)
    @status = assert_valid_status(status)
  end

  def delivered?
    to_sym == :delivered
  end

  def sent?
    [:sent, :delivered].include?(to_sym)
  end

  def failed?
    to_sym == :failed
  end

  def unknown?
    to_sym == :unknown
  end

  def humanize
    TranslatedConstants.humanized[to_sym]
  end

  def <=>(other)
    return nil unless other

    a = TranslatedConstants.humanized.keys.index(to_sym)
    b = TranslatedConstants.humanized.keys.index(other.to_sym)
    a <=> b
  end

  def to_sym
    status
  end

  # Untranslated version of the delivery status.
  #
  # Returns a String
  def to_s
    status.to_s
  end

  # Translated version of the delivery status.
  #
  # Returns a String
  def to_s!
    TranslatedConstants.to_s![status]
  end

  # Capitalized version of the translated delivery status.
  #
  # Returns a String
  def capitalize
    to_s!.capitalize
  end

  def inspect
    obj_id = format("0x00%x", object_id << 1)
    %Q(#<#{self.class}:#{obj_id} @status=:#{ status }>)
  end

  private

  attr_reader :status

  def assert_valid_status(status)
    unless TranslatedConstants.humanized.key?(status)
      raise ArgumentError, "Invalid delivery status: #{ status }"
    end

    status
  end
end
