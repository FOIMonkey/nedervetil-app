# == Schema Information
#
# Table name: attachment_management_revisions
#
#  id                    :bigint           not null, primary key
#  foi_attachment_id     :bigint           not null
#  user_id               :bigint           not null
#  parent_id             :bigint
#  kind                  :string           not null
#  status                :string           default("processing"), not null
#  source_sha256         :string           not null
#  source_content_type   :string           not null
#  source_filename       :text             not null
#  instructions          :jsonb            not null
#  engine                :string
#  output_sha256         :string
#  output_content_type   :string
#  output_filename       :text
#  output_byte_size      :bigint
#  report                :jsonb            not null
#  error                 :text
#  reason                :text
#  applied_by_id         :bigint
#  applied_at            :datetime
#  info_request_event_id :bigint
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#

module AttachmentManagement
  # Working-copy draft for editing an FoiAttachment. Transitions out of
  # processing/ready use with_status_lock so terminal drafts never revert.
  class Revision < ApplicationRecord
    self.table_name = 'attachment_management_revisions'

    KINDS = %w[pdf_redaction image_redaction text_edit upload office_pdf].freeze
    STATUSES = %w[
      processing ready failed applied superseded discarded expired
    ].freeze

    belongs_to :foi_attachment
    belongs_to :user
    belongs_to :parent, class_name: 'AttachmentManagement::Revision',
                        optional: true
    belongs_to :applied_by, class_name: 'User', optional: true
    belongs_to :info_request_event, optional: true

    has_one_attached :output, service: :attachments

    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: STATUSES }
    validates :source_sha256, :source_content_type, :source_filename,
              presence: true

    scope :newest_first, -> { order(created_at: :desc, id: :desc) }
    scope :open, -> { where(status: %w[processing ready]) }

    STATUSES.each do |name|
      define_method(:"#{name}?") { status == name }
    end

    # Redact-only users can only confirm redactions (not uploads/free edits),
    # even if drafted before requester replacement access was turned off.
    def confirmable_by?(ability)
      return true if ability.can?(:replace_attachment, foi_attachment)

      case kind
      when 'pdf_redaction'
        parent_id.nil? ||
          (parent&.kind == 'office_pdf' &&
           Capabilities.new(foi_attachment).word_processing? &&
           parent.user_id == ability.user&.id)
      when 'text_edit'
        foi_attachment.main_body_part? && instructions['redaction_only'] == true
      else false
      end
    end

    def format_change?
      output_content_type.present? &&
        output_content_type != foi_attachment.content_type
    end

    def boxes
      Boxes.from_instructions(instructions)
    end

    def output_bytes
      output.download
    end

    def previews
      Previews.new(attachment_id: foi_attachment_id,
                   sha256: output_sha256,
                   content_type: output_content_type) { output_bytes }
    end

    def output_kind
      case output_content_type
      when 'application/pdf' then :pdf
      when *Engines::Raster::IMAGE_CODERS.keys then :image
      when *Capabilities::TEXT then :text
      else :other
      end
    end

    def kind_label
      {
        'pdf_redaction' => _('Redacted PDF (pages rebuilt from images)'),
        'image_redaction' => _('Redacted image'),
        'text_edit' => _('Edited text'),
        'upload' => _('Uploaded replacement'),
        'office_pdf' => _('Converted to PDF by LibreOffice')
      }.fetch(kind)
    end

    def status_label
      return _('Still processing (is the job runner running?)') if stuck?

      {
        'processing' => _('Processing'),
        'ready' => _('Ready to check'),
        'failed' => _('Failed'),
        'applied' => _('Applied'),
        'superseded' => _('Out of date'),
        'discarded' => _('Discarded'),
        'expired' => _('Expired')
      }.fetch(status)
    end

    def stuck?
      processing? && updated_at < 10.minutes.ago
    end

    def discard!
      leave!('discarded', from: %w[processing ready failed])
    end

    def leave!(new_status, from: %w[processing ready])
      moved = with_status_lock(from) do
        update!(status: new_status)
        output.purge if output.attached?
      end
      Previews.clear(foi_attachment_id, output_sha256) if moved && output_sha256
      moved
    end

    def with_status_lock(statuses)
      ran = false
      with_lock do
        next unless statuses.include?(status)

        yield
        ran = true
      end
      ran
    end
  end
end
