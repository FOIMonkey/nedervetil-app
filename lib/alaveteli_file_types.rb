require "marcel"
require "stringio"

# Maps file extensions to MIME types and detects content MIME types with Marcel
# plus a UTF-8 plain-text fallback for application/octet-stream.
class AlaveteliFileTypes
  # To add an image, create a file with appropriate name corresponding to the
  # mime type in app/assets/images/content_type/ e.g. icon_image_tiff_large.png
  FILE_EXTENSION_TO_MIME_TYPE = {
    'csv' => 'text/csv',
    "txt" => 'text/plain',
    "pdf" => 'application/pdf',
    "rtf" => 'application/rtf',
    "doc" => 'application/vnd.ms-word',
    # rubocop:disable Layout/LineLength -- a table of MIME types
    "docx" => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    "xls" => 'application/vnd.ms-excel',
    "xlsx" => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    "xlsm" => 'application/vnd.ms-excel.sheet.macroenabled.12',
    "xlsb" => 'application/vnd.ms-excel.sheet.binary.macroenabled.12',
    "docm" => 'application/vnd.ms-word.document.macroenabled.12',
    "ppt" => 'application/vnd.ms-powerpoint',
    "pptx" => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    # rubocop:enable Layout/LineLength
    "pptm" => 'application/vnd.ms-powerpoint.presentation.macroenabled.12',
    "ppsm" => 'application/vnd.ms-powerpoint.slideshow.macroenabled.12',
    "eml" => 'message/rfc822',
    "oft" => 'application/vnd.ms-outlook',
    "msg" => 'application/vnd.ms-outlook',
    "tnef" => 'application/ms-tnef',
    "tif" => 'image/tiff',
    "gif" => 'image/gif',
    "jpeg" => 'image/jpeg',
    "jpg" => 'image/jpeg',
    "png" => 'image/png',
    "bmp" => 'image/bmp',
    "htm" => 'text/html',
    "html" => 'text/html',
    "vcf" => 'text/x-vcard',
    "zip" => 'application/zip',
    "delivery-status" => 'message/delivery-status'
  }.freeze
  # Duplicate MIME types (e.g. image/jpeg) map to the last extension listed
  # above, so preferred extensions (jpg, html) should come after aliases.
  MIME_TYPE_TO_FILE_EXTENSION = FILE_EXTENSION_TO_MIME_TYPE.invert

  class << self
    # Given file name and its content, return most likely type
    def filename_and_content_to_mimetype(filename, content)
      filename_to_mimetype(filename) || content_to_mimetype(content)
    end

    def content_to_mimetype(content)
      mime_type = Marcel::MimeType.for(StringIO.new(content))
      return mime_type unless mime_type == 'application/octet-stream'

      # Marcel cannot detect plain text from content alone (unlike
      # libmagic/Mahoro). Check if content is valid text as a fallback.
      text_content?(content) ? 'text/plain' : mime_type
    end

    def filename_to_mimetype(filename)
      return nil unless filename

      match = /\.([^.]+)$/i.match(filename)
      match && FILE_EXTENSION_TO_MIME_TYPE[match[1].downcase]
    end

    def text_content?(content)
      return false if content.nil? || content.empty?

      utf8 = content.dup.force_encoding('UTF-8')
      utf8.valid_encoding? && !utf8.match?(/[\x00-\x08\x0E-\x1F]/)
    end

    def mimetype_to_extension(mimetype)
      if MIME_TYPE_TO_FILE_EXTENSION.include?(mimetype)
        return MIME_TYPE_TO_FILE_EXTENSION[mimetype]
      end

      nil
    end
  end
end
