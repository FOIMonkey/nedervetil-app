# == Schema Information
#
# Table name: request_deadline_adjustments
#
#  id                       :bigint           not null, primary key
#  info_request_id          :bigint           not null
#  user_id                  :bigint
#  stage                    :string           not null
#  basis_event_id           :bigint           not null
#  due_on                   :date             not null
#  original_due_on          :date             not null
#  original_very_overdue_on :date
#  reason                   :string           not null
#  note                     :text
#  cleared_at               :datetime
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#

module Deadlines
  # Adjusted due date for a request stage. Response adjustments sync to core's
  # date_response_required_by/date_very_overdue_after; review stages live only
  # here. Clock restarts (clarification, resend) supersede prior adjustments.
  class Adjustment < ApplicationRecord
    include Clearable

    self.table_name = 'request_deadline_adjustments'
    STAGES = %w[response review review_request].freeze

    belongs_to :info_request, inverse_of: :deadline_adjustments
    belongs_to :user, optional: true # NULL once the user is deleted
    validates :user, presence: true, on: :create

    validates :stage, inclusion: { in: STAGES }
    validate :reason_suits_stage
    validates :due_on, :original_due_on, :basis_event_id, presence: true
    validates :note, length: { maximum: 1000 }
    validate :due_on_is_sensible

    def self.current(request, stage)
      adjustment = latest_active(request, stage: stage)
      adjustment if adjustment&.in_force?
    end

    def self.apply!(request, stage:, user:, due_on:, reason:, note: nil)
      request.with_lock do
        # Re-checked under lock in case a reply arrived concurrently.
        unless NextAction.for(request).adjustable_stage == stage
          raise ArgumentError, "no #{stage} deadline to change"
        end

        basis = Stage.basis_event(request, stage) or
          raise ArgumentError, "no #{stage} deadline to change"
        previous = active_for(request, stage: stage).order(:id).last
        previous = nil unless previous&.basis_event_id == basis.id
        original_due = previous&.original_due_on ||
                       Stage.computed_due_on(request, stage)
        original_very = previous&.original_very_overdue_on ||
                        (request.date_very_overdue_after if stage == 'response')
        adjustment = new(info_request: request,
                         user: user,
                         stage: stage,
                         basis_event_id: basis.id,
                         due_on: due_on,
                         reason: reason,
                         note: note.presence,
                         original_due_on: original_due,
                         original_very_overdue_on: original_very)
        adjustment.validate!
        clear_active!(request, stage: stage)
        adjustment.save!
        if stage == 'response'
          adjustment.write_core_dates(
            adjustment.due_on,
            very_overdue_after(request, adjustment.due_on)
          )
        end
        adjustment
      end
    end

    def self.clear!(request, stage)
      request.with_lock do
        adjustment = active_for(request, stage: stage).order(:id).last
        return unless adjustment

        if stage == 'response' && adjustment.in_force?
          adjustment.write_core_dates(adjustment.original_due_on,
                                      adjustment.original_very_overdue_on)
        end
        clear_active!(request, stage: stage)
        adjustment
      end
    end

    def self.very_overdue_after(request, due_on)
      gap = request.late_calculator.reply_very_late_after_days -
            request.late_calculator.reply_late_after_days
      Calendar.due_date_for(request, from: due_on, days: gap)
    end

    def in_force?
      return false unless active?
      unless Stage.basis_event(info_request, stage)&.id == basis_event_id
        return false
      end
      return true unless stage == 'response'

      info_request.read_attribute(:date_response_required_by) == due_on
    end

    def superseded?
      active? && !in_force?
    end

    def reason_label
      REASONS.key?(reason) ? _(REASONS.fetch(reason)) : reason
    end

    def write_core_dates(due_on, very_overdue_on)
      info_request.update!(
        date_response_required_by: due_on,
        date_very_overdue_after:
          very_overdue_on ||
          self.class.very_overdue_after(info_request, due_on)
      )
    end

    private

    def reason_suits_stage
      return unless info_request

      unless Deadlines.stage_reasons(stage, Deadlines.regime(info_request)).
             include?(reason)
        errors.add(:reason, _('is not one of the choices for this date'))
      end
    end

    def due_on_is_sensible
      return unless due_on && info_request

      start = Stage.basis_event(info_request, stage)&.created_at&.to_date
      due_on_near_start(start)
      return unless stage == 'response' && start

      due_on_within_the_law(start)
    end

    def due_on_near_start(start)
      if start && due_on <= start
        errors.add(:due_on, _('must be after the date the clock started'))
      end
      return unless start && due_on > start + 1.year

      errors.add(:due_on, _('must be within a year'))
    end

    def due_on_within_the_law(start)
      if original_due_on && due_on < original_due_on
        errors.add(:due_on,
                   _("can't be earlier than the date the law gives ({{date}})",
                     date: original_due_on.strftime('%-d %B')))
      end
      return unless reason == 'eir_extension'

      limit = Calendar.working_days_after(start,
                                          Deadlines.eir_extension_days,
                                          Deadlines.regime(info_request))
      return unless due_on > limit

      errors.add(:due_on,
                 _('can be at most 40 working days after they got it ' \
                   '({{date}})',
                   date: limit.strftime('%-d %B')))
    end
  end
end
