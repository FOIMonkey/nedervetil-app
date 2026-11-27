# Adds has_rich_text_without_attachments to strip ActionText attachments on
# every save path (autosave, direct save, validate: false), blocking
# attachment injection even beyond UI and upload-route restrictions.
module ActionText::WithoutAttachments
  def has_rich_text_without_attachments(name)
    has_rich_text name
    rich_texts_without_attachments << name.to_s
  end

  def rich_texts_without_attachments
    @rich_texts_without_attachments ||= []
  end

  # Removes attachments from rich text whose record forbids them.
  module RemoveAttachments
    extend ActiveSupport::Concern

    included do
      # Prepended so it runs before ActionText's own before_validation, which
      # attaches every blob the body refers to as an embed.
      before_validation :remove_attachments,
                        prepend: true, if: :attachments_forbidden?
      before_save :remove_attachments, if: :attachments_forbidden?
    end

    private

    def attachments_forbidden?
      record.class.try(:rich_texts_without_attachments)&.include?(name)
    end

    def remove_attachments
      tag = ActionText::Attachment.tag_name
      nodes = body&.fragment&.find_all(tag) || []
      blobs = locate_blobs(nodes)

      if nodes.any?
        self.body = ActionText::Content.new(
          body.fragment.update { |html| html.css(tag).remove }
        )
      end

      # Detaching purges each blob later, unless it is attached elsewhere.
      self.embeds = [] if embeds.attached?
      purge_unattached_blobs(blobs)
    end

    def locate_blobs(nodes)
      nodes.filter_map do |node|
        sgid = node['sgid']
        next if sgid.blank?

        attachable = GlobalID::Locator.locate_signed(sgid, for: 'attachable')
        attachable if attachable.is_a?(ActiveStorage::Blob)
      rescue ActiveRecord::RecordNotFound
        nil
      end.uniq
    end

    def purge_unattached_blobs(blobs)
      blobs.each { |blob| blob.purge_later if blob.attachments.none? }
    end
  end
end

ActiveSupport.on_load(:action_text_rich_text) do
  include ActionText::WithoutAttachments::RemoveAttachments
end
