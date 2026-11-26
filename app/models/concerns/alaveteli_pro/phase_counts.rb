module AlaveteliPro
  # Mixed into User to count inbox RequestSummaries by phase, draft state and,
  # when enabled, IncomingAttention state for the dashboard sidebar.
  module PhaseCounts
    extend ActiveSupport::Concern

    def phase_counts
      @phase_counts ||= phase_counts!
    end

    def phase_counts!
      if IncomingAttention::Effective.active?
        return @phase_counts = attention_phase_counts
      end

      # Create a Hash that has a default value of 0 for new/unset keys
      hash_with_default = Hash.new(0)

      # Calculate the phase totals from the request_summary_categories
      raw_counts =
        request_summaries.
          joins(:request_summary_categories).
          references(:request_summary_categories).
          group("request_summary_categories.slug").
          count("request_summary_categories.id")
      raw_counts['not_drafts'] = request_summaries.not_category(:draft).count

      @phase_counts =
        hash_with_default.merge(raw_counts).with_indifferent_access
    end

    private

    # With AI reading on, a request's phase depends on whether its replies
    # need attention, which the stored categories don't know.
    def attention_phase_counts
      effective = IncomingAttention::Effective
      counts = Hash.new(0).with_indifferent_access
      InfoRequest::State.phases.each do |phase|
        counts[phase[:scope]] = effective.phase_summaries(
          request_summaries, phase[:scope], user: self
        ).count
      end
      counts['not_drafts'] = request_summaries.not_category(:draft).count
      counts['draft'] = request_summaries.category(:draft).count
      counts.merge!(effective.counts(self))
    end
  end
end
