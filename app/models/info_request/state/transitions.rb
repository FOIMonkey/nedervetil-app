class InfoRequest
  module State
    # Builds localised HTML labels for status-choice forms, tailored to
    # whether the viewer owns the request. Used by State::Calculator.
    module Transitions
      # A status-choice label for the target state and current user.
      #
      # @param to_state [String] target status
      # @option opts [Boolean] :is_owning_user required
      # @option opts [Boolean] :in_internal_review default false
      # @return [String]
      def self.transition_label(to_state, opts = {})
        user = opts.fetch(:is_owning_user) ? "owner" : "other_user"
        method = "#{user}_#{to_state}_transition_label"
        if respond_to?(method, true)
          send(method, opts)
        else
          raise "No transition_label for #{to_state}. Should an #{user} " \
                "be transitioning to this state? (looking for method " \
                "named #{method})"
        end
      end

      # @param states [Array<String>] target statuses
      # @param opts [Hash] forwarded to .transition_label
      # @return [Hash] state => label
      def self.labelled_hash(states, opts = {})
        hash = {}
        states.each do |state|
          hash[state] = transition_label(state, opts)
        end
        hash
      end

      def self.owner_waiting_response_transition_label(_opts = {})
        _("I'm still <strong>waiting</strong> for my information " \
          "<small>(maybe you got an acknowledgement)</small>")
      end

      def self.owner_not_held_transition_label(_opts = {})
        _("They do <strong>not have</strong> the information " \
          "<small>(maybe they say who does)</small>")
      end

      def self.owner_rejected_transition_label(_opts = {})
        _("I've received <strong>no information</strong>")
      end

      def self.owner_partially_successful_transition_label(_opts = {})
        _("I've received <strong>some of the information</strong>")
      end

      def self.owner_successful_transition_label(_opts = {})
        _("I've received <strong>all the information</strong>")
      end

      def self.owner_waiting_clarification_transition_label(_opts = {})
        _("I've been asked to <strong>clarify</strong> my request")
      end

      def self.owner_gone_postal_transition_label(_opts = {})
        _("They are going to reply <strong>by postal mail</strong>")
      end

      def self.owner_internal_review_transition_label(opts = {})
        if opts.fetch(:in_internal_review, false) ||
           opts.fetch(:internal_review_requested, false)
          _("I'm still <strong>waiting</strong> for the internal review")
        else
          _("I'm waiting for an <strong>internal review</strong> response")
        end
      end

      def self.owner_under_appeal_transition_label(_opts = {})
        _("I've <strong>appealed</strong> to the regulator or a tribunal")
      end

      def self.owner_error_message_transition_label(_opts = {})
        _("I've received an <strong>error message</strong>")
      end

      def self.owner_requires_admin_transition_label(_opts = {})
        _("This request <strong>requires administrator attention</strong>")
      end

      def self.owner_user_withdrawn_transition_label(_opts = {})
        _("I would like to <strong>withdraw this request</strong>")
      end

      def self.other_user_waiting_response_transition_label(_opts = {})
        _("<strong>No response</strong> has been received <small>(maybe " \
          "there's just an acknowledgement)</small>")
      end

      def self.other_user_not_held_transition_label(_opts = {})
        _("The authority do <strong>not have</strong> the information " \
          "<small>(maybe they say who does)</small>")
      end

      def self.other_user_rejected_transition_label(_opts = {})
        _('<strong>No information</strong> has been sent')
      end

      def self.other_user_partially_successful_transition_label(_opts = {})
        # TODO: - trailing space copied from
        # views/request/_other_describe_state.html.erb, will it break
        # translations if I fix it?
        _("<strong>Some of the information</strong> has been sent ")
      end

      def self.other_user_successful_transition_label(_opts = {})
        _("<strong>All the information</strong> has been sent")
      end

      def self.other_user_waiting_clarification_transition_label(_opts = {})
        _("<strong>Clarification</strong> has been requested")
      end

      def self.other_user_gone_postal_transition_label(_opts = {})
        _("A response will be sent <strong>by postal mail</strong>")
      end

      def self.other_user_internal_review_transition_label(opts = {})
        if opts.fetch(:in_internal_review, false) ||
           opts.fetch(:internal_review_requested, false)
          _("Still awaiting an <strong>internal review</strong>")
        else
          # To match what would happen if this method didn't exist, because
          # it shouldn't for this situation
          raise "Only the request owner can request an internal_review."
        end
      end

      def self.other_user_error_message_transition_label(_opts = {})
        _("An <strong>error message</strong> has been received")
      end
    end
  end
end
