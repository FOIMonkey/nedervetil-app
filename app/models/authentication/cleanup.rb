module Authentication
  # Expire only the new, bounded pending records.
  class Cleanup
    def self.run
      [AuthenticationReturn, AuthenticationEnrolment, PendingEmailChange,
       PendingRequestDraft].each do |model|
        model.where(expires_at: ..Time.current).delete_all
      end
    end
  end
end
