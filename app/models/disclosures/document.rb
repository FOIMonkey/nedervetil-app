module Disclosures
  # Slim public catalogue entry backed directly by one FoiAttachment#file.
  class Document < ApplicationRecord
    self.table_name = 'disclosure_documents'

    KINDS = Disclosures::KINDS
    KIND_LABELS = { 'decision_letter' => N_('Decision letter'),
                    'released_records' => N_('Released records') }.freeze
    FORMATS = %w[pdf spreadsheet csv document presentation text image
                 other].freeze
    FORMAT_LABELS = {
      'pdf' => N_('PDF'),
      'spreadsheet' => N_('Spreadsheet'),
      'csv' => N_('CSV'),
      'document' => N_('Word document'),
      'presentation' => N_('Presentation'),
      'text' => N_('Text'),
      'image' => N_('Image'),
      'other' => N_('Other')
    }.freeze
    STATES = %w[draft published withdrawn].freeze
    SOURCE_KINDS = %w[attachment email_text].freeze
    WITHDRAWAL_KINDS = %w[manual source_changed thread_replaced
                          consent_withdrawn request_deleted erasing
                          erased].freeze
    STAGES = {
      erased: N_('Erased'),
      erasing: N_('Being erased'),
      withdrawn: N_('Withdrawn'),
      taken_down: N_('Taken down for review'),
      held: N_('Held for review'),
      listed: N_('Public'),
      unlisted: N_('Published, not public'),
      in_review: N_('Waiting for review'),
      not_ready: N_('Not ready'),
      ready: N_('Ready to publish')
    }.freeze
    PUBLIC_ID = /\A[a-z0-9]{12}\z/

    LISTED_JOINS = <<~SQL.squish.freeze
      INNER JOIN foi_attachments listed_attachments
        ON listed_attachments.id = disclosure_documents.foi_attachment_id
      LEFT OUTER JOIN incoming_messages listed_messages
        ON listed_messages.id = listed_attachments.incoming_message_id
      LEFT OUTER JOIN info_requests listed_requests
        ON listed_requests.id = listed_messages.info_request_id
    SQL

    LISTED_SQL = <<~SQL.squish.freeze
      disclosure_documents.state = 'published'
      AND disclosure_documents.erased_at IS NULL
      AND listed_attachments.prominence = 'public'
      AND listed_attachments.erased_at IS NULL
      AND listed_attachments.masking_failed_at IS NULL
      AND ((disclosure_documents.request_deleted_at IS NOT NULL
            AND disclosure_documents.owner_id IS NOT NULL
            AND listed_attachments.incoming_message_id IS NULL)
           OR (disclosure_documents.request_deleted_at IS NULL
               AND listed_messages.id IS NOT NULL
               AND listed_requests.id IS NOT NULL
               AND #{Ability::RequesterVisible.sql(request: 'listed_requests',
                                                   message: 'listed_messages')}))
    SQL

    belongs_to :info_request, optional: true
    belongs_to :public_body, optional: true
    belongs_to :incoming_message, optional: true
    belongs_to :foi_attachment, optional: true
    belongs_to :info_request_batch, optional: true
    belongs_to :created_by, class_name: 'User', optional: true
    belongs_to :updated_by, class_name: 'User', optional: true
    belongs_to :published_by, class_name: 'User', optional: true
    belongs_to :withdrawn_by, class_name: 'User', optional: true
    belongs_to :owner, class_name: 'User', optional: true

    has_many :pages,
             -> { order(:number) },
             class_name: 'Disclosures::Page',
             inverse_of: :document,
             dependent: :destroy
    has_many :events,
             -> { order(:id) },
             class_name: 'Disclosures::Event',
             inverse_of: :document,
             dependent: :delete_all
    has_one_attached :thumbnail, service: :attachments

    validates :public_id, format: { with: PUBLIC_ID }
    validates :kind, inclusion: { in: KINDS }
    validates :state, inclusion: { in: STATES }
    validates :source_kind, inclusion: { in: SOURCE_KINDS }
    validates :withdrawal_kind, inclusion: { in: WITHDRAWAL_KINDS },
                                allow_nil: true
    validates :title, presence: true, length: { maximum: 200 }
    validates :description, length: { maximum: 2_000 }

    before_validation :assign_public_id, on: :create

    scope :listed, -> { joins(LISTED_JOINS).where(LISTED_SQL) }

    scope :requester_visible, -> {
      joins(<<~SQL.squish).
        LEFT OUTER JOIN foi_attachments requester_attachments
          ON requester_attachments.id = disclosure_documents.foi_attachment_id
        LEFT OUTER JOIN incoming_messages requester_messages
          ON requester_messages.id = requester_attachments.incoming_message_id
        LEFT OUTER JOIN info_requests requester_requests
          ON requester_requests.id = requester_messages.info_request_id
      SQL
        where(Ability::RequesterVisible.sql(request: 'requester_requests',
                                            message: 'requester_messages',
                                            file: 'requester_attachments')).
        where('requester_requests.id = disclosure_documents.info_request_id')
    }

    def self.find_public!(public_id)
      raise ActiveRecord::RecordNotFound unless public_id.to_s.match?(PUBLIC_ID)

      find_by!(public_id: public_id)
    end

    def self.kind_label(kind)
      _(KIND_LABELS.fetch(kind))
    end

    def to_param
      public_id
    end

    def draft?
      state == 'draft'
    end

    def published?
      state == 'published'
    end

    def withdrawn?
      state == 'withdrawn'
    end

    def listed?
      return false unless published? && erased_at.nil?

      attachment = foi_attachment
      return false unless attachment&.is_public? && !attachment.erased? &&
                          !attachment.masking_failed? &&
                          attachment.file.attached?

      if request_deleted?
        owner_id.present? && attachment.incoming_message_id.nil?
      else
        message = attachment.incoming_message
        request = message&.info_request
        message.present? && request.present? &&
          Ability::RequesterVisible.own(message) == :requester &&
          Ability::RequesterVisible.requester?(request)
      end
    end

    alias listable? listed?

    def stage
      STAGES.each_key.find { |name| stage_holds?(name) }
    end

    def stage_in?(*names)
      left = STAGES.keys
      until left.empty?
        return true if left.all? { names.include?(_1) }
        return false if left.none? { names.include?(_1) }

        name = left.shift
        if name == :listed && left.first == :unlisted &&
           names.include?(:listed) == names.include?(:unlisted)
          name = left.shift
        end
        return names.include?(name) if stage_holds?(name)
      end
      false
    end

    def public_view
      PublicDocument.new(self)
    end

    def erased?
      erased_at.present?
    end

    def erasure_pending?
      withdrawal_kind == 'erasing'
    end

    def erasure_started?
      erased? || erasure_pending?
    end

    def ever_published?
      first_published_at.present?
    end

    def kind_label
      self.class.kind_label(kind)
    end

    def format
      super.presence ||
        (foi_attachment &&
         Formats.declared(foi_attachment.content_type,
                          foi_attachment.filename)) || 'other'
    end

    def format_label
      _(FORMAT_LABELS.fetch(format, 'Other'))
    end

    def content_type
      foi_attachment&.content_type
    end

    def filename
      foi_attachment&.filename
    end

    def byte_size
      foi_attachment&.file_blob&.byte_size
    end

    def bytes
      foi_attachment.file.download
    end

    def download_filename
      Titles.filename(title, Formats.file_extension(filename, content_type))
    end

    def servable?
      foi_attachment.present? && !foi_attachment.erased? &&
        !foi_attachment.masking_failed? && foi_attachment.file.attached?
    end

    def request_deleted?
      request_deleted_at.present?
    end

    def requester
      request_deleted? ? owner : info_request&.user
    end

    def requester_id
      request_deleted? ? owner_id : info_request&.user_id
    end

    def authority
      info_request&.public_body || public_body
    end

    def batch_siblings
      Document.none
    end

    def request_siblings
      Document.none
    end

    def unpublished_changes?
      false
    end

    def processing?
      false
    end

    def log!(action, user: nil, **details)
      events.create!(action: action,
                     user: user,
                     details: details)
    end

    def withdraw!(kind:, reason:, by: nil)
      unless WITHDRAWAL_KINDS.include?(kind)
        raise ArgumentError, "unknown withdrawal kind #{kind}"
      end

      now = Time.current
      columns = { state: 'withdrawn',
                  withdrawn_at: now,
                  withdrawn_by_id: by&.id,
                  withdrawal_kind: kind,
                  withdrawal_reason: reason,
                  updated_at: now }
      columns[:updated_by_id] = by.id if by
      update_columns(columns)
    end

    def take_down_and_start_again!(by:, reason: 'Withdrawn by requester')
      if foi_attachment&.manual_black_mask?
        raise Error::Refused,
              _('An admin has redacted this file, so it can’t be restored ' \
                'from the email.')
      end
      now = Time.current
      foi_attachment.make_requester_only!(at: now) if foi_attachment&.is_public?
      columns = { state: 'draft',
                  withdrawn_at: nil,
                  withdrawn_by_id: nil,
                  withdrawal_kind: nil,
                  withdrawal_reason: nil,
                  updated_at: now }
      columns[:updated_by_id] = by.id if by
      update_columns(columns)
      purge_public_pages!
      outcome = foi_attachment ? foi_attachment.start_again! : :email_gone
      if outcome == :restored && foi_attachment
        restored_format = Formats.declared(foi_attachment.content_type,
                                           foi_attachment.filename)
        update_columns(format: restored_format, updated_at: Time.current)
      end
      log!('withdrawn', user: by, start_again: true,
                        restored: outcome == :restored, reason: reason)
      outcome
    end

    def purge_public_pages!
      pages.find_each do |page|
        page.image.purge if page.image.attached?
        page.destroy!
      end
      pages.reset
      thumbnail.purge if thumbnail.attached?
      TopicMatch.where(document_id: id).delete_all
      update_columns(page_count: nil,
                     render_notes: {},
                     hidden_content: [],
                     updated_at: Time.current)
    end

    def rebuild_pages_from_attachment!
      return true unless foi_attachment&.file&.attached?

      Renderer.new(self).run
      TopicMatch.record(self) if published?
      true
    rescue StandardError => e
      Rails.logger.warn("Disclosures::Document #{id}: page rebuild failed " \
                        "(#{e.class}: #{e.message})")
      false
    end

    private

    def stage_holds?(name)
      case name
      when :erased then erased?
      when :erasing then erasure_pending?
      when :withdrawn then withdrawn? && withdrawal_kind != 'source_changed'
      when :taken_down then withdrawal_kind == 'source_changed'
      when :held then false
      when :listed then listed?
      when :unlisted then published?
      when :in_review then ReviewSubmission.pending?(self)
      when :not_ready then !servable?
      when :ready then true
      end
    end

    def assign_public_id
      self.public_id ||= loop do
        candidate = SecureRandom.alphanumeric(12).downcase
        break candidate unless self.class.exists?(public_id: candidate)
      end
    end
  end
end
