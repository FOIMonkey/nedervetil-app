# Sanitises HTML attachments with Loofah (:prune), stripping remote images
# and falling back to escaped text if nesting exceeds max_tree_depth.
module FoiAttachment::HTMLSanitising
  LOCAL_MEDIA_REF = /\A[a-z0-9][a-z0-9._-]*\z/i
  MEDIA_ELEMENTS = 'img, video, audio, source, track, embed, object, input'.
    freeze

  def sanitise_html(html)
    html = collapse_redundant_nesting(html)
    document = Loofah.html5_document(html) do |config|
      config[:max_tree_depth] = 800
    end.scrub!(:prune)

    strip_external_media(document)

    document.to_html(encoding: 'UTF-8')
  rescue ArgumentError
    sanitise_html_as_text(html)
  end

  private

  # Block remote/data media and beacon attributes; allow bare local filenames.
  def strip_external_media(document)
    document.css('[srcset], [imagesrcset], [ping], [poster]').each do |node|
      strip_media_attributes(node)
    end
    document.css(MEDIA_ELEMENTS).each { |node| strip_media_element(node) }
  end

  def strip_media_attributes(node)
    node.remove_attribute('srcset')
    node.remove_attribute('imagesrcset')
    node.remove_attribute('ping')
    poster = node['poster']
    node.remove_attribute('poster') if poster && !poster.match?(LOCAL_MEDIA_REF)
  end

  def strip_media_element(node)
    if node.name == 'input'
      src = node['src']
      node.remove_attribute('src') if src && !src.match?(LOCAL_MEDIA_REF)
      return
    end

    ref = node.name == 'object' ? node['data'] : node['src']
    node.remove unless ref&.match?(LOCAL_MEDIA_REF)
  end

  def collapse_redundant_nesting(html)
    html.
      gsub(%r{(?:<div>\s*){30,}}i, '<div>').
      gsub(%r{(?:</div>\s*){30,}}i, '</div>')
  end

  def sanitise_html_as_text(html)
    CGI.escapeHTML(html.gsub(/<[^>]+>/, ' ').squeeze(' ').strip)
  end
end
