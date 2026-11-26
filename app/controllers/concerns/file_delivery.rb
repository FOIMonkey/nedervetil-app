# Shared transport for untrusted files and generated page images. Callers keep
# their existing download/preview policies; these policies are not equivalent.
module FileDelivery
  DOCUMENT_CSP = "default-src 'none'; sandbox".freeze
  ATTACHMENT_CSP = "default-src 'none'; img-src 'self'; " \
                   "style-src 'unsafe-inline'; sandbox".freeze

  # Plain text also permits inline viewing, with an explicit UTF-8 charset.
  INLINE_TYPES = %w[
    application/pdf image/png image/jpeg image/gif image/webp image/bmp
  ].freeze

  def self.inline_viewable?(content_type)
    INLINE_TYPES.include?(content_type) || content_type == 'text/plain'
  end

  private

  def send_file_content(data = nil, filename:, content_type:, csp:,
                        path: nil, inline: false)
    response.headers['content-security-policy'] = csp if csp
    inline &&= FileDelivery.inline_viewable?(content_type)
    type = if content_type == 'text/plain'
             'text/plain; charset=utf-8'
           else
             content_type
           end
    send_file_response(data, path: path, filename: filename, type: type,
                             disposition: inline ? 'inline' : 'attachment')
  end

  def send_png_content(data = nil, path: nil, url_based_filename: false)
    options = { type: 'image/png', disposition: 'inline' }
    options[:url_based_filename] = true if path && url_based_filename
    send_file_response(data, path: path, **options)
  end

  def send_file_response(data, path:, **options)
    # send_data renders; keep Rails' Vary handling on the send_file path too.
    _set_vary_header
    path ? send_file(path, **options) : send_data(data, **options)
  end
end
