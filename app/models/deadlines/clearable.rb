module Deadlines
  # Soft-clears deadline records via cleared_at (never deleted) to preserve
  # history and stay transaction-safe. Includers must declare belongs_to
  # :info_request with inverse_of.
  module Clearable
    extend ActiveSupport::Concern

    included do
      scope :active, -> { where(cleared_at: nil) }
    end

    def active?
      cleared_at.nil?
    end

    class_methods do
      # Queries DB directly for callers holding the request lock.
      def active_for(request, **conditions)
        active.where(info_request_id: request.id, **conditions)
      end

      def latest_active(request, **conditions)
        records = request.association(request_association)
        unless records.loaded?
          return active_for(request, **conditions).order(:id).last
        end

        records.target.select do |record|
          record.active? &&
            conditions.all? { |name, value| record.public_send(name) == value }
        end.max_by(&:id)
      end

      def clear_active!(request, **conditions)
        active_for(request, **conditions).update_all(cleared_at: Time.current)
      end

      private

      def request_association
        reflect_on_association(:info_request).options.fetch(:inverse_of)
      end
    end
  end
end
