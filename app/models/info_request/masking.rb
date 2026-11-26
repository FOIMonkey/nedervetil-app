# Selects censor rules and address masks for a request's views (see
# doc/FORK.md). Rules are memoized via Current.memo and never cached on the
# record; callers needing newly added rules run in Current.without_memo.
module InfoRequest::Masking
  extend ActiveSupport::Concern

  VIEWS = %i[admins requester pack public ai].freeze

  # Precedence: request, global, authority, requester (newest first in each).
  def applicable_censor_rules
    return load_applicable_censor_rules unless persisted?

    Current.memo(:censor_rules, id, public_body_id, user_id) do
      load_applicable_censor_rules
    end
  end

  # Site contact and authority request address masks; public_body may be nil
  # for a document kept after its request was deleted.
  def self.address_masks(public_body)
    masks = [
      { to_replace: AlaveteliConfiguration.contact_email,
        replacement: _("[{{site_name}} contact email]",
                       site_name: AlaveteliConfiguration.site_name) }
    ]

    if public_body&.is_followupable?
      masks << { to_replace: public_body.request_email,
                 replacement: _("[{{public_body}} request email]",
                                public_body: public_body.short_or_long_name) }
    end
    masks
  end

  def masks
    masks = InfoRequest::Masking.address_masks(public_body)
    return masks unless persisted?

    masks.insert(1, { to_replace: incoming_email,
                      replacement: _('[FOI #{{request}} email]',
                                     request: id.to_s) })
  end

  def masks_for(view)
    case view
    when :admins then MaskSet.none
    when :requester, :pack
      black = applicable_censor_rules.select(&:black?)
      MaskSet.new(censor_rules: black, masks: [], default_masks: false)
    when :public, :ai
      MaskSet.new(censor_rules: applicable_censor_rules.to_a,
                  masks: coloured_masks, default_masks: true)
    else
      raise ArgumentError, "no such view of a request's masks: #{view.inspect}"
    end
  end

  def apply_censor_rules(text, content_type, **options)
    masks_for(:requester).apply(text, content_type, **options)
  end

  def apply_all_masks(text, content_type, **options)
    masks_for(:public).apply(text, content_type, **options)
  end

  private

  def coloured_masks
    masks.map { |mask| mask.merge(colour: 'orange') }
  end

  def load_applicable_censor_rules
    query = <<-SQL
    SELECT cr.* FROM censor_rules cr
      WHERE (
          cr.censorable_type = 'InfoRequest'
          AND cr.censorable_id = :info_request_id
        OR cr.censorable_id IS NULL
          AND cr.censorable_type IS NULL
        OR cr.censorable_type = 'PublicBody'
          AND cr.censorable_id = :public_body_id
        OR cr.censorable_type = 'User'
          AND cr.censorable_id = :user_id
      )
    ORDER BY
      (CASE WHEN cr.censorable_type = 'InfoRequest' THEN 0
         WHEN cr.censorable_type IS NULL THEN 1
         WHEN cr.censorable_type = 'PublicBody' THEN 2
         ELSE 3
       END) ASC,
      cr.created_at DESC
    SQL
    CensorRule.find_by_sql [
      query,
      {
        info_request_id: id,
        public_body_id: public_body_id,
        user_id: user_id
      }
    ]
  end
end
