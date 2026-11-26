class InfoRequest
  # Defines valid InfoRequest states, short display descriptions and inbox
  # phase metadata shared by models, filters and views.
  module State
    def self.all
      states = [
        'waiting_response',
        'waiting_clarification',
        'gone_postal',
        'not_held',
        # this is called 'refused' in UK FOI law and the user interface, but
        # 'rejected' internally for historic reasons
        'rejected',
        'successful',
        'partially_successful',
        'internal_review',
        'under_appeal',
        'error_message',
        'requires_admin',
        'user_withdrawn',
        'attention_requested',
        'vexatious',
        'not_foi'
      ]
      if InfoRequest.custom_states_loaded
        states += InfoRequest.theme_extra_states
      end
      states
    end

    def self.unhappy
      %w(partially_successful rejected waiting_response_very_overdue)
    end

    def self.valid?(state)
      all.include?(state)
    end

    def self.short_description(state)
      descriptions = {
        'waiting_classification' => _('Waiting classification'),
        'waiting_response' => _('Waiting response'),
        'waiting_response_overdue' => _('Waiting response, overdue'),
        'waiting_response_very_overdue' =>
              _('Waiting response, long overdue'),
        'not_held' => _('No information'),
        'rejected' => _('No information'),
        'partially_successful' => _('Some information provided'),
        'successful' => _('All information provided'),
        'waiting_clarification' => _('Waiting clarification'),
        'gone_postal' => _("Handled by postal mail"),
        'internal_review' => _('Internal review'),
        'under_appeal' => _('Under appeal'),
        'error_message' => _("Delivery error"),
        'requires_admin' => _("Requires admin attention"),
        'attention_requested' => _("Reported"),
        'user_withdrawn' => _("Withdrawn"),
        'vexatious' => _("Vexatious"),
        'not_foi' => _("Not an FOI request")
      }
      if descriptions[state]
        descriptions[state]
      elsif InfoRequest.respond_to?(:theme_short_description)
        InfoRequest.theme_short_description(state)
      else
        raise _("unknown status {{state}}", state: state)
      end
    end

    def self.phases
      [
        { capital_label: _('Waiting response'),
          label: _('awaiting response'),
          scope: :awaiting_response,
          param: 'awaiting-response' },
        { capital_label: _('Waiting response, overdue'),
          label: _('overdue'),
          scope: :overdue,
          param: 'overdue' },
        { capital_label: _('Waiting response, long overdue'),
          label: _('very overdue'),
          scope: :very_overdue,
          param: 'very-overdue' },
        { capital_label: _('Response received'),
          label: _('response received'),
          scope: :response_received,
          param: 'response-received' },
        { capital_label: _('Clarification needed'),
          label: _('clarification needed'),
          scope: :clarification_needed,
          param: 'clarification-needed' },
        { capital_label: _('Complete'),
          label: _('complete'),
          scope: :complete,
          param: 'complete' },
        { capital_label: _('Other'),
          label: _('other'),
          scope: :other,
          param: 'other' }
      ]
    end

    def self.phase_params
      Hash[phases.map { |atts| [atts[:scope], atts[:param]] }]
    end
  end
end
