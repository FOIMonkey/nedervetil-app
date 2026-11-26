module AttachmentManagement
  # Prepares page count and initial boxes for the box-drawing redaction editor.
  module BoxEditor
    private

    def prepare_box_editor(parent: nil, boxes: {})
      @parent = parent
      @image = parent.nil? && capabilities.kind == :image
      @page_count = if parent
                      parent.previews.page_count
                    else
                      attachment_previews.page_count
                    end
      kept = boxes.select { |page, _| page.between?(1, @page_count) }
      @boxes_json = kept.transform_keys(&:to_s).to_json
      @title = _('Draw redaction boxes')
    end
  end
end
