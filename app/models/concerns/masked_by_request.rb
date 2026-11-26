# Delegates censor-rule and mask application to info_request while recording
# redactions against self. Call info_request directly to avoid recording.
module MaskedByRequest
  extend ActiveSupport::Concern

  include Redactable

  def apply_censor_rules(text, content_type, redacted_attribute:,
                         masked: false, unmasked: nil, matched: nil)
    return text unless info_request

    info_request.apply_censor_rules(
      text, content_type,
      redactable: self, redacted_attribute: redacted_attribute,
      masked: masked, unmasked: unmasked, matched: matched
    )
  end

  def apply_all_masks(text, content_type, redacted_attribute:,
                      masked: false, unmasked: nil, matched: nil)
    return text unless info_request

    info_request.apply_all_masks(
      text, content_type,
      redactable: self, redacted_attribute: redacted_attribute,
      masked: masked, unmasked: unmasked, matched: matched
    )
  end
end
