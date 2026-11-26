module Disclosures
  class Renderer
    # Renders an image attachment as a single page PNG and thumbnail.
    class Image < Kind
      private

      def pages(path, dir)
        engine = Disclosures.engine(job: job)
        coder = engine.coder_for(attachment.content_type) or
          raise Error::Refused, _('This kind of picture can’t be shown here.')

        frames = engine.image_info(path, coder)[:frames]
        outcome.notes['frames'] = frames if frames > 1
        png = engine.render_image(path, coder, File.join(dir, 'picture.png'))
        outcome.page_count = 1
        add_image_page(1, 'Picture', png, '', 'none')
        thumbnail(png, dir)
      end
    end
  end
end
