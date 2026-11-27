# Mixed into User to check erasure eligibility and irreversibly scrub personal
# details, identifying associations and credentials on a closed, unbanned
# account.
module User::Erasable
  extend ActiveSupport::Concern

  # Banned accounts cannot be erased because the ban is enforced by email.
  def erasable?
    closed? && !banned?
  end

  def erase_later(editor:, reason:)
    User::ErasureJob.perform_later(self, editor: editor, reason: reason)
  end

  def erase(...)
    erase!(...)
  rescue ActiveRecord::RecordInvalid
    false
  end

  # Keeps the same editor:/reason: interface as FoiAttachment::Erasable#erase
  # and User::ErasureJob; User has no event log to record them against.
  def erase!(editor:, reason:) # rubocop:disable Lint/UnusedMethodArgument -- matches FoiAttachment::Erasable#erase and User::ErasureJob
    raise ActiveRecord::RecordInvalid unless erasable?

    with_lock do
      raise ActiveRecord::RecordInvalid unless erasable?

      destroy_identifying_associations

      outgoing_messages.update!(
        from_name: _('[Name Removed]')
      )

      erase_account
      erase_authentication_material
      true
    end
  end

  private

  def destroy_identifying_associations
    slugs.destroy_all
    sign_ins.destroy_all
    email_histories.destroy_all
    permission_changes.destroy_all
    notifications.delete_all
    AttachmentManagement::Revision.where(user_id: id).find_each(&:discard!)
    info_requests.pluck(:id).each do |request_id|
      RegulatorPack.purge_for_request!(request_id)
    end
  end

  def erase_account
    sha = Digest::SHA1.hexdigest(rand.to_s)

    update!(
      name: _('[Name Removed]'),
      email: "#{sha}@invalid",
      url_name: sha,
      password: nil,
      password_confirmation: nil
    )
  end

  def erase_authentication_material
    update_columns(
      authentication_version: SecureRandom.uuid,
      credential_reset_required: true, otp_required_for_login: true,
      encrypted_password: '', reset_password_token: nil,
      reset_password_sent_at: nil, confirmation_token: nil,
      confirmation_sent_at: nil, confirmed_at: nil,
      unconfirmed_email: nil, email_confirmed: false,
      otp_secret: nil, consumed_timestep: nil, devise_otp_backup_codes: [],
      hashed_password: '', salt: nil, login_token: nil,
      otp_secret_key: nil, otp_enabled: false, otp_counter: nil,
      otp_last_used_at: nil, otp_enabled_at: nil,
      otp_backup_codes_generated_at: nil
    )
    # otp_backup_codes is now an alias for the Devise column. Address the
    # retained physical legacy column explicitly so both stores are erased.
    self.class.where(id: id).update_all('"otp_backup_codes" = NULL')
    [authentication_returns, authentication_enrolments, pending_email_changes,
     pending_request_drafts, post_redirects].each(&:delete_all)
  end
end
