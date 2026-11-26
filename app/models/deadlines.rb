# One next action for every request, worked out from core's own states, events
# and due dates. No new request statuses.
module Deadlines
  # Statutory working-day limits (FOIA/EIR/FOISA/EIR(S)): review_request_days
  # (s.45 Code, EIR reg 11(2), FOISA s.20(5), EIR(S) reg 16(2)), review_days
  # (20; EIR reg 11(4) allows 40), eir_extension_days (reg 7), and
  # clarify_scotland_days (Scottish Code).
  # Calendar windows: ico_window (6w guidance), sic_window (6m, FOISA s.47(4)),
  # clarify_window (2m ICO guidance).
  mattr_accessor :review_request_days, default: 40
  mattr_accessor :review_days, default: {
    'foi' => 20,
    'eir' => 40,
    'foisa' => 20,
    'eisr' => 20
  }
  mattr_accessor :eir_extension_days, default: 40
  mattr_accessor :clarify_scotland_days, default: 40
  mattr_accessor :ico_window, default: 6.weeks
  mattr_accessor :sic_window, default: 6.months
  mattr_accessor :clarify_window, default: 2.months

  # Either tag marks a Scottish authority; some carry sic without scotland.
  mattr_accessor :scotland_tag, default: 'scotland'
  mattr_accessor :sic_tag, default: 'sic'

  SCOTTISH = %w[foisa eisr].freeze

  REASONS = {
    'public_interest' => N_('Public interest extension'),
    'eir_extension' => N_('EIR extension (complex and voluminous)'),
    'fee_notice' => N_('Fee notice'),
    'review_extension' => N_('Review extended'),
    'authority_letter' => N_('Date given in the authority’s letter'),
    'agreed' => N_('Agreed with the authority'),
    'other' => N_('Other')
  }.freeze

  # FOISA has no extension of its own (s.10); only FOI has a public interest
  # extension (s.10(3)); only the EIRs extend for complex and voluminous
  # requests (reg 7); only the FOI Code lets a review run past 20 working days.
  def self.stage_reasons(stage, regime)
    case stage
    when 'response'
      case regime
      when 'foi' then %w[public_interest fee_notice agreed other]
      when 'eir', 'eisr' then %w[eir_extension fee_notice agreed other]
      else %w[fee_notice agreed other]
      end
    when 'review'
      regime == 'foi' ? %w[review_extension agreed other] : %w[agreed other]
    when 'review_request' then %w[authority_letter agreed other]
    else []
    end
  end

  def self.scottish_body?(body)
    !!body && (body.has_tag?(scotland_tag) || body.has_tag?(sic_tag))
  end

  def self.scottish?(regime)
    SCOTTISH.include?(regime)
  end

  def self.regime(request)
    law = request.law_used.presence || 'foi'
    if scottish_body?(request.public_body)
      return law == 'eir' ? 'eisr' : 'foisa'
    end

    law
  end
end
