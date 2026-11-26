# The clipped attachment text was a search snippet; requests are not indexed,
# so nothing reads it. The full text is extracted on demand as before.
class RemoveCachedAttachmentTextClippedFromIncomingMessages < ActiveRecord::Migration[8.1]
  def change
    remove_column :incoming_messages, :cached_attachment_text_clipped, :text
  end
end
