class Ability
  # Visitors see published, listed documents, and the version each one
  # publishes. So does everyone else: these rules apply to every account.
  # Nothing else is public. Requests, their correspondence and batches are
  # private (PrivateArchive::Policy).
  module VisitorRules
    private

    def visitor_rules
      can :read, Disclosures::Document do |document|
        document.stage_in?(:listed)
      end
    end
  end
end
