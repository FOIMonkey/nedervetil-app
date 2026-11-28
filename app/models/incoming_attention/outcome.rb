module IncomingAttention
  # Maps Worker /v1/outcome calls to core request statuses; "unsure" leaves
  # status to the requester. Modes (INCOMING_OUTCOME_MODE): off, shadow, apply.
  module Outcome
    MODES = %w[off shadow apply].freeze
    MAX_ATTEMPTS = 5
    CALLS = %w[all some not_held refused clarification pending unsure].freeze
    # "not_held" maps to core's "rejected"; outcome_call preserves the
    # distinction for display labels.
    STATES = { 'all' => 'successful',
               'some' => 'partially_successful',
               'not_held' => 'rejected',
               'refused' => 'rejected',
               'clarification' => 'waiting_clarification' }.freeze
    LABELS = { 'successful' => N_('All information released'),
               'partially_successful' => N_('Some information released'),
               'rejected' => N_('No information: refused'),
               'waiting_clarification' => N_('Clarification requested') }.freeze
    NIL_LABEL = N_('Information released: nil return').freeze
    PARTS = { 'part_not_held' => N_('part not held'),
              'part_unaddressed' => N_('part not answered'),
              'suppressed' => N_('small numbers withheld') }.freeze
    NAMES = { 'cost_limit' => N_('the cost limit'),
              'vexatious' => N_('vexatious or repeated request'),
              'ncnd' => N_('neither confirm nor deny'),
              'personal_data' => N_('personal data'),
              'published' => N_('information already published'),
              'other_exemption' => N_('another exemption') }.freeze

    module_function

    def mode
      value = AlaveteliConfiguration.incoming_outcome_mode
      MODES.include?(value) ? value : 'off'
    end

    def active?
      Config.enabled? && mode != 'off'
    end

    def strict_documents?
      AlaveteliConfiguration.incoming_outcome_strict_documents == true
    end

    def ocr?
      AlaveteliConfiguration.incoming_outcome_ocr == true &&
        FoiAttachment::Ocr.available?
    end

    def applying?
      Config.enabled? && mode == 'apply'
    end

    # prediction must be freshly read: a stale outcome_checked_at fails the
    # CAS silently and Recovery only scans pending/running rows.
    def queue(prediction, message)
      return unless active? && prediction && prediction.outcome_status.nil?
      return if Effective.routine?(message)
      return if OptOut.opted_out?(message.info_request&.user)

      queued = Prediction.move_outcome(prediction.id, nil,
                                       prediction.outcome_checked_at,
                                       outcome_status: 'pending')
      Job.perform_later(prediction.id) if queued
    rescue StandardError => e
      Rails.logger.warn('request_outcome_enqueue_failed ' \
                        "prediction_id=#{prediction&.id} #{e.class}")
    end

    # Fail-closed guard: shortened text or omitted documents (in strict mode)
    # downgrade any non-pending Worker call to "unsure".
    def floor(result, request)
      guard = if request['text_shortened']
                'truncated'
              elsif request['strict_documents'] &&
                    request['omitted_documents'].to_i.positive?
                'documents_omitted'
              end
      return result if guard.nil? || %w[pending unsure].include?(result['call'])

      result.merge('call' => 'unsure',
                   'reasons' => [guard],
                   'withheld_under' => [])
    end

    def apply(request)
      return unless applying?

      request.with_lock do
        return unless request.awaiting_description?

        rows = relevant(request)
        return if still_waiting?(rows)

        decided = decided_rows(rows)
        latest = decided.last
        return unless latest && STATES.key?(latest.outcome_call)

        last_event = request.info_request_events.last
        unless last_event&.event_type == 'response' &&
               last_event.incoming_message_id == latest.incoming_message_id
          return
        end

        state = state_for(latest, decided)
        Classification.automatically { request.set_described_state(state) }
        latest.update_columns(outcome_applied_state: state,
                              auto_classified: true)
      end
    end

    def still_waiting?(rows)
      rows.empty? ||
        rows.any? { |row| %w[pending running].include?(row.outcome_status) }
    end

    def decided_rows(rows)
      rows.select do |row|
        row.outcome_status == 'complete' && row.outcome_call != 'pending'
      end
    end

    def state_for(latest, decided)
      calls = decided.map(&:outcome_call)
      if latest.outcome_call == 'clarification'
        STATES['clarification']
      elsif calls.include?('all')
        STATES['all']
      elsif calls.include?('some')
        STATES['some']
      else
        STATES.fetch(latest.outcome_call)
      end
    end

    def relevant(request)
      basis = if defined?(Deadlines::Stage)
                Deadlines::Stage.review_basis(request)
              end
      messages = request.incoming_messages.order(:id).to_a
      if basis
        messages = messages.select do |m|
          m.response_event && m.response_event.id > basis.id
        end
      end
      Prediction.
        where(incoming_message_id: messages.map(&:id), human_reviewed_at: nil).
        where.not(outcome_status: nil).order(:incoming_message_id).to_a
    end

    def label(prediction)
      # Invalidation clears the reading (outcome_status) but keeps the applied
      # state as the decision marker deadlines rely on, so check both.
      unless applying? && prediction && prediction.human_reviewed_at.nil? &&
             prediction.outcome_status == 'complete'
        return
      end

      return unless label_stands?(prediction)
      return NIL_LABEL if nil_return_applied?(prediction)
      return N_('No information: not held') if not_held_refusal?(prediction)
      if prediction.outcome_applied_state
        return LABELS[prediction.outcome_applied_state]
      end

      N_('Outcome unclear: please check') if prediction.outcome_call == 'unsure'
    end

    def label_stands?(prediction)
      if prediction.outcome_applied_state
        prediction.info_request&.described_state ==
          prediction.outcome_applied_state
      elsif prediction.outcome_call == 'unsure'
        prediction.info_request&.awaiting_description?
      else
        true
      end
    end

    def not_held_refusal?(prediction)
      prediction.outcome_applied_state == 'rejected' &&
        prediction.outcome_call == 'not_held'
    end

    def exemptions(prediction)
      words(prediction&.outcome_signals&.fetch('mentions', nil))
    end

    def weak_all?(prediction)
      prediction&.outcome_applied_state == STATES['all'] &&
        Array(prediction.outcome_signals&.fetch('reasons', nil)).
          include?('weak_hints')
    end

    def nil_return_applied?(prediction)
      prediction.outcome_applied_state == STATES['all'] &&
        Array(prediction.outcome_signals&.fetch('reasons', nil)).
          include?('nil_return')
    end

    def partial_reasons(prediction)
      return [] unless prediction&.outcome_call == 'some'

      reasons = Array(prediction.outcome_signals&.fetch('reasons', nil))
      withheld = words(prediction.outcome_signals&.fetch('withheld_under', nil))
      named = if withheld.any?
                [_('withheld under {{exemptions}}',
                   exemptions: withheld.to_sentence)]
              else
                []
              end
      named + PARTS.filter_map { |key, text| _(text) if reasons.include?(key) }
    end

    def words(codes)
      Array(codes).grep(String).
        map { |code| NAMES.key?(code) ? _(NAMES[code]) : code }.uniq
    end

    def overridden!(request, new_state)
      Prediction.
        where(info_request_id: request.id, outcome_overridden_from: nil).
        where.not(outcome_applied_state: [nil, new_state]).
        update_all('outcome_overridden_from = outcome_applied_state')
    end
  end
end
