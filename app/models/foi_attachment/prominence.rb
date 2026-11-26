# Direct prominence writes (public, requester_only, hidden) via update_columns
# so publication/masking/erasure skip callbacks, attention invalidation and
# event logging. Also namespaces FoiAttachment::Prominence::Helper.
module FoiAttachment::Prominence
  def make_public!(at: Time.current)
    update_columns(prominence: 'public', updated_at: at)
  end

  # Unconditionally overwrites hidden; check is_public? first if required.
  def make_requester_only!(at: Time.current)
    update_columns(prominence: 'requester_only', updated_at: at)
  end

  # Hides on unmasked black-rule match, preserving the first masking_failed_at.
  def hide_for_black_rule!(reason:)
    now = Time.zone.now
    update_columns(
      prominence: 'hidden',
      prominence_reason: reason,
      black_masked: true,
      masking_failed_at: masking_failed_at || now,
      updated_at: now
    )
  end

  # The caller removes the stored file.
  def hide_as_erased!(at:)
    update_columns(erased_at: at, prominence: 'hidden', updated_at: at)
  end
end
