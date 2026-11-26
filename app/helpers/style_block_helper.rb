# Strips <style> blocks and their CSS text before Rails' sanitize (which only
# removes disallowed tags and would leave CSS behind as plain text).
module StyleBlockHelper
  def sanitize_without_style_blocks(html, **options)
    if html.to_s.match?(/<style\b/i)
      fragment = Loofah.html5_fragment(html.to_s)
      fragment.css('style').remove
      html = fragment.to_html
    end
    sanitize(html, **options)
  end
end
