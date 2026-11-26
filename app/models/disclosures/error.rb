module Disclosures
  # Disclosure errors with user-facing messages. Stale: changed since page load.
  # NotReady: source file is mid-masking. NeedsAdmin: requires admin review.
  class Error < StandardError
    Refused = Class.new(self)
    NotReady = Class.new(Refused)
    NeedsAdmin = Class.new(Refused)
    Stale = Class.new(self)
  end
end
