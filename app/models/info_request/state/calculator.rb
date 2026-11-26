class InfoRequest
  module State
    # Returned by InfoRequest#state. Maps a request's status to its inbox
    # phase, summarised phase group and allowed status transitions.
    class Calculator
      PHASES = {
        'not_held' => :complete,
        'rejected' => :complete,
        'successful' => :complete,
        'partially_successful' => :complete,
        'user_withdrawn' => :complete,
        'waiting_clarification' => :clarification_needed,
        'waiting_response' => :awaiting_response,
        'waiting_response_overdue' => :overdue,
        'waiting_response_very_overdue' => :very_overdue,
        'gone_postal' => :other,
        'internal_review' => :other,
        'under_appeal' => :other,
        'error_message' => :other,
        'requires_admin' => :other,
        'attention_requested' => :other,
        'vexatious' => :other,
        'not_foi' => :other
      }.freeze

      def initialize(info_request)
        @info_request = info_request
      end

      def phase(cached_value_ok = false)
        return :response_received if @info_request.awaiting_description?

        PHASES[@info_request.calculate_status(cached_value_ok)]
      end

      # Available status choices, grouped as :pending, :complete and :other.
      #
      # @option opts [Boolean] :cached_value_ok allow cached status (false)
      # @option opts [Boolean] :user_asked_to_update_status offer more choices
      #   when the user explicitly requests a status update (false)
      # @see InfoRequest::State::Transitions.transition_label
      # @return [Hash] group => { state => label }; other options are forwarded
      def transitions(opts = {})
        cached_value_ok = opts.fetch(:cached_value_ok, false)
        state = @info_request.calculate_status(cached_value_ok)
        if admin_states.include?(state)
          return {
            pending: {},
            complete: {},
            other: {}
          }
        end
        opts[:in_internal_review] = state == 'internal_review'
        opts[:internal_review_requested] =
          @info_request.internal_review_requested?
        build_transitions_hash(opts)
      end

      # A summarised version of #phase, grouping the phases down into 3 groups
      def summarised_phase(cached_value_ok = false)
        phase = phase(cached_value_ok)
        case phase
        when :awaiting_response
          :in_progress
        when :complete
          :complete
        when :other
          :other
        when :response_received,
               :clarification_needed,
               :overdue,
               :very_overdue
          :action_needed
        end
      end

      private

      def build_transitions_hash(opts)
        hash = {}
        [:pending, :complete, :other].each do |group|
          method = "#{group}_states"
          states = send(method, opts)
          hash[group] = Transitions.labelled_hash(states, opts)
        end
        hash
      end

      def pending_states(opts)
        # Which pending states can we transition into
        if opts.fetch(:in_internal_review, false)
          states = %w[internal_review gone_postal]
        else
          states = []
          if opts.fetch(:internal_review_requested, false)
            states += ['internal_review']
          end
          states += %w[
            waiting_response
            waiting_clarification
            gone_postal
          ]
          if opts.fetch(:user_asked_to_update_status, false)
            states += ['internal_review']
          end
        end
        # An appeal to the regulator or a tribunal is the requester's own step.
        states += ['under_appeal'] if opts.fetch(:is_owning_user, false)
        states.uniq
      end

      def complete_states(_opts = {})
        # States from which a request can go no further, because it's complete
        # (not_held is stored as rejected)
        %w[
          partially_successful
          successful
          rejected
        ]
      end

      def admin_states(_opts = {})
        # States which only an admin can put a request into, and from which
        # a normal user can't get the request out again
        %w[not_foi vexatious]
      end

      def other_states(opts = {})
        is_owning_user = opts.fetch(:is_owning_user, false)
        user_asked_to_update_status =
          opts.fetch(:user_asked_to_update_status, false)
        states = ['error_message']
        if user_asked_to_update_status && is_owning_user
          states += %w[requires_admin user_withdrawn]
        end
        states
      end
    end
  end
end
