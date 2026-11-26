class Ability
  # Visitors cannot read requests, correspondence or batches
  # (PrivateArchive::Policy). Public document read rules join in B07/B13.
  module VisitorRules
    private

    def visitor_rules
    end
  end
end
