module IncomingAttention
  module Outcome
    # The refusal sections a reply cites, found by core's own legislation
    # reference parser (the one behind refusal advice).
    module Signals
      # UK postcodes ("Clowne S43 4JY") otherwise read as section references.
      POSTCODE = /\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b/i
      # Strip citations to non-FOI/EIR Acts (e.g. "Section 30 of the Local
      # Government Finance Act 1992") while keeping FOI/EIR/"the Act".
      NUMBERS = /\d+(?:\s*(?:\([a-z0-9]{1,6}\)|\.[a-z0-9]{1,6}))*/i
      # rubocop:disable Layout/LineLength
      OURS = /freedom\s+of\s+information|environmental\s+information|\bfoi(?:sa|a)?\b|\beir\b|
              \bthe\s+(?:said\s+|above\s+|\d{4}\s+)?(?:act|regulations)\b/ix
      # rubocop:enable Layout/LineLength
      OTHER_ACT = /
        \b(?:sections?|ss?|regulations?|regs?)\.?\s*#{NUMBERS}
        (?:\s*(?:,|\bor\b|\band\b|&(?:amp;)?)\s*#{NUMBERS})*
        \s+of\s+
        (?!(?:said\s+|above\s+|\d{4}\s+)?(?:act|regulations)\b)
        (?:(?!#{OURS})[^\n.;:]){1,80}?\b(?:act|regulations|order)\b
      /ix

      module_function

      def cited(text, legislation)
        text = text.to_s.gsub(POSTCODE, ' ').gsub(OTHER_ACT, ' ')
        legislation.find_references(text).select(&:refusal?).
          map { |ref| ref.parent.to_s }.uniq
      rescue StandardError => e
        # The text is a reply's, so only the exception's class is logged.
        Rails.logger.warn("request_outcome_citations_failed #{e.class}")
        []
      end
    end
  end
end
