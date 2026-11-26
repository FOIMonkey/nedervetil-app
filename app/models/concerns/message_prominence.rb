# Shared prominence validation and prominence_reason normalisation for
# IncomingMessage, OutgoingMessage and FoiAttachment.
module MessageProminence
  extend ActiveSupport::Concern

  included do
    normalizes :prominence_reason, with: Whitespace::TRIM_TO_NIL
    validates_inclusion_of :prominence,
                           in: ->(record) { record.class.prominence_states }
  end

  def is_public?
    prominence == 'normal'
  end

  # Default prominence states for models including MessageProminence.
  module ClassMethods
    # Visible to the requester ('normal') or admins only ('hidden').
    def prominence_states
      %w(normal hidden)
    end
  end
end
