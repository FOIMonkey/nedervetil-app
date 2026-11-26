# == Schema Information
#
# Table name: disclosure_events
#
#  id          :bigint           not null, primary key
#  document_id :bigint           not null
#  user_id     :bigint
#  action      :string           not null
#  details     :jsonb            not null
#  created_at  :datetime         not null
#

module Disclosures
  # Audit trail, seen by the requester and admins.
  class Event < ApplicationRecord
    self.table_name = 'disclosure_events'

    LABELS = {
      'created' => N_('Document made'),
      'review_requested' => N_('Sent for admin review'),
      'publication_unwanted' => N_('Requester no longer wants it published'),
      'hide_requested' => N_('Requester asked for something to be hidden'),
      'details_changed' => N_('Details changed'),
      'version_made' => N_('Version made'),
      'version_failed' => N_('Version failed'),
      'version_discarded' => N_('Version discarded'),
      'published' => N_('Published'),
      'metadata_approved' => N_('New public details approved'),
      'withdrawn' => N_('Withdrawn'),
      'erased' => N_('Document erased'),
      'source_changed' => N_('Source changed in the thread'),
      'copies_erased' => N_('Files erased'),
      'original_erased' => N_('Original as received and old versions erased'),
      'erasure_requested' => N_('Erasure requested'),
      'erasure_pending' => N_('Erasure pending: files will be retried'),
      'request_deleted' => N_('Its request was deleted'),
      'thread_replaced' => N_('Attachment replaced in the thread'),
      'name_masked' => N_('Requester name masked'),
      'name_consent' => N_('Requester agreed to their name showing'),
      'name_consent_withdrawn' => N_('Requester withdrew their agreement')
    }.freeze

    belongs_to :document,
               class_name: 'Disclosures::Document',
               inverse_of: :events
    belongs_to :user, optional: true

    validates :action, presence: true

    def label
      _(LABELS.fetch(action, action.humanize))
    end
  end
end
