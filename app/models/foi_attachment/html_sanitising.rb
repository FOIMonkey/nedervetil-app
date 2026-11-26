# Sanitises HTML attachments with Loofah (:prune), stripping remote images
# and falling back to escaped text if nesting exceeds max_tree_depth.
module FoiAttachment::HTMLSanitising
  def sanitise_html(html)
    html = collapse_redundant_nesting(html)
    document = Loofah.html5_document(html) do |config|
      config[:max_tree_depth] = 800
    end.scrub!(:prune)

    # Block remote/data images; allow only bare local filenames.
    document.css('img').each do |image|
      src = image['src']
      image.remove unless src&.match?(/\A[a-z0-9][a-z0-9._-]*\z/i)
    end

    document.to_html(encoding: 'UTF-8')
  rescue ArgumentError
    sanitise_html_as_text(html)
  end

  private

  def collapse_redundant_nesting(html)
    html.
      gsub(%r{(?:<div>\s*){30,}}i, '<div>').
      gsub(%r{(?:</div>\s*){30,}}i, '</div>')
  end

  def sanitise_html_as_text(html)
    CGI.escapeHTML(html.gsub(/<[^>]+>/, ' ').squeeze(' ').strip)
  end
end
