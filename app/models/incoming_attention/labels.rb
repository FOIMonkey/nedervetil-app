module IncomingAttention
  # Presentation hints only. The Worker names a reply; these never grant
  # routine eligibility, rewrite a human outcome or change notifications.
  module Labels
    ROUTINE = { 'ACKNOWLEDGEMENT' => N_('Acknowledgement') }.freeze
    ATTENTION = { 'DELIVERY_PROBLEM' => N_('Delivery problem'),
                  'ACTION_REQUESTED' => N_('Reply or action requested'),
                  'DECISION' => N_('Likely decision or review response'),
                  'SUBSTANTIVE' => N_('Substantive response') }.freeze

    module_function

    def visible_to?(message, user, ability)
      Effective.active? && user && ability.can?(:read, message.info_request) &&
        ability.can?(:read, message) &&
        (message.info_request.user_id == user.id ||
          ability.can?(:admin, message.info_request))
    end

    def for_message(message, **options)
      described(message, **options)&.last
    end

    def routine?(message, **options)
      described(message, **options)&.first == :routine
    end

    # [kind, label], the kind being :outcome, :routine or :attention.
    def described(message, decision: Effective.decision(message), prediction: :lookup, current: :lookup)
      kind = decision.routine? ? :routine : :attention
      fallback = [
        kind,
        kind == :routine ? N_('Routine update') : N_('Other reply to review')
      ]
      prediction = Prediction.for_message(message) if prediction == :lookup
      outcome = Outcome.label(prediction)
      return [:outcome, outcome] if outcome
      return fallback unless prediction && !prediction.truncated?

      fresh = if current == :lookup
                prediction.current?(message)
              else
                current && prediction.status == 'complete'
              end
      return fallback unless fresh

      # Pick the Worker label matching the current bucket (including overrides).
      labels = prediction.reply_labels
      return fallback unless labels.is_a?(Hash)

      label = if kind == :routine
                ROUTINE[labels['routine']]
              else
                ATTENTION[labels['attention']]
              end
      label ? [kind, label] : fallback
    rescue StandardError => e
      Rails.logger.warn('incoming_attention_label_failed ' \
                        "message_id=#{message&.id} #{e.class}")
      fallback
    end
  end
end
