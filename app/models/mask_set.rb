MaskSet = Data.define(:censor_rules, :masks, :default_masks) do
  def self.none
    new(censor_rules: [], masks: [], default_masks: false)
  end

  def none?
    censor_rules.empty? && masks.empty? && !default_masks
  end

  def colours
    held = censor_rules.map(&:colour) + masks.pluck(:colour)
    held << 'orange' if default_masks
    Disclosures::MASK_COLOURS & held
  end

  def apply(text, content_type, redactable: nil, redacted_attribute: nil,
            masked: false, unmasked: nil, matched: nil)
    return text if none?

    AlaveteliTextMasker.apply_masks(
      text, content_type,
      censor_rules: censor_rules, masks: masks,
      default_masks: default_masks, redactable: redactable,
      redacted_attribute: redacted_attribute, masked: masked,
      unmasked: unmasked, matched: matched
    )
  end
end
