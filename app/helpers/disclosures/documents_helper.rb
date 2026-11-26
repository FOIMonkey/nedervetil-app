module Disclosures
  # View helpers for documents. Disclosures::Titles formats a date with
  # document_date outside a view, so the first methods are module functions.
  module DocumentsHelper
    ORIGINAL_FORMAT_NAMES = {
      '.doc' => N_('Word document'),
      '.docx' => N_('Word document'),
      '.docm' => N_('Word document'),
      '.odt' => N_('OpenDocument text'),
      '.rtf' => N_('Rich Text document'),
      '.xls' => N_('Excel spreadsheet'),
      '.xlsx' => N_('Excel spreadsheet'),
      '.xlsm' => N_('Excel spreadsheet'),
      '.xlsb' => N_('Excel spreadsheet'),
      '.ods' => N_('OpenDocument spreadsheet'),
      '.ppt' => N_('PowerPoint presentation'),
      '.pptx' => N_('PowerPoint presentation'),
      '.odp' => N_('OpenDocument presentation'),
      '.csv' => N_('CSV file'),
      '.txt' => N_('Text file'),
      '.html' => N_('HTML file'),
      '.htm' => N_('HTML file'),
      '.pdf' => N_('PDF')
    }.freeze

    module_function

    def document_date(date)
      date ? I18n.l(date.to_date, format: '%-d %B %Y') : ''
    end

    def document_format_line(version)
      return '' unless version

      parts = [version.format_label]
      if version.page_count.to_i.positive? && version.format != 'csv'
        count = version.page_count
        parts <<
          if version.format == 'spreadsheet'
            n_('{{count}} sheet', '{{count}} sheets', count, count: count)
          else
            n_('{{count}} page', '{{count}} pages', count, count: count)
          end
      end
      if version.byte_size
        parts << ActionController::Base.helpers.
          number_to_human_size(version.byte_size)
      end
      parts.join(', ')
    end

    # Checks stage_in? first to avoid per-row listed?/review-request queries.
    def document_state(document)
      return _('Published') if document.stage_in?(:listed, :unlisted)
      return _('Draft') if document.stage_in?(:in_review, :not_ready, :ready)

      case document.stage
      when :erasing then _('Erasure pending')
      when :erased then _('Erased')
      when :withdrawn then _('Withdrawn')
      when :taken_down then _('Taken down for review')
      when :held then _('Held for review')
      end
    end

    def requester_document_state(document)
      if ReviewSubmission.pending?(document)
        return _('Waiting for admin review')
      end

      document_state(document)
    end

    def reply_to_share?(row)
      row.main.any? do |file|
        document = file.document or next true
        document.stage_in?(:not_ready, :ready) &&
          can?(:publish_own_document, document)
      end
    end

    # From any asset path, so a theme can add an icon for a type core lacks.
    def document_icon_path(version)
      name = "content_type/icon_#{version&.content_type.to_s.sub('/', '_')}" \
             '_large.png'
      if DocumentsHelper.icons.include?(name)
        name
      else
        'content_type/icon_unknown.png'
      end
    end

    def self.icons
      @icons ||= Rails.application.config.assets.paths.
        flat_map do |path|
          Dir.glob('content_type/*.png', base: path.to_s)
        end.to_set
    end

    # Core raises a RuntimeError for a status it can't describe. The message
    # isn't logged: core's message can include the request's events.
    def outcome(info_request)
      status = info_request.calculate_status
      [status, InfoRequest::State.short_description(status)]
    rescue RuntimeError => e
      Rails.logger.error('Disclosures::DocumentsHelper#outcome failed for ' \
                         "request #{info_request.id}: #{e.class}")
      [nil, nil]
    end

    def private_note_for(requester_id, user)
      you = user && requester_id == user.id
      if you
        _('Private: only you and the site’s admins can see it.')
      else
        _('Private: only the requester and the site’s admins can see it.')
      end
    end

    def filter_params(search, key, value)
      params = search.filters.merge(q: search.query.presence)
      params[:sort] = search.sort unless search.sort == Search::SORTS.first
      value.nil? ? params.delete(key) : params[key] = value
      if respond_to?(:request_journey_choices) && request_journey_pro? &&
         self.params[:request_choice].present?
        params[:request_choice] = request_journey_choices
      end
      params.compact
    end

    def document_short_date(date)
      date ? I18n.l(date.to_date, format: '%-d %b %Y') : ''
    end

    def document_format_tag(version)
      extension = Formats.file_extension(version.filename,
                                         version.content_type).
        delete_prefix('.').upcase
      if extension.match?(/\A[A-Z0-9]{2,4}\z/) && extension != 'BIN'
        extension
      else
        version.format_label
      end
    end

    def document_converted_from_note(document)
      metadata = document&.foi_attachment&.file_blob&.metadata
      return nil unless metadata.is_a?(Hash)

      from_type = Formats.normalized_type(
        metadata['converted_from_content_type']
      )
      from_ext = normalized_conversion_extension(
        metadata['converted_from_extension'], from_type
      )
      return nil if from_type.blank? && from_ext.blank?

      current_type = Formats.normalized_type(document.content_type)
      current_ext = Formats.file_extension(document.filename,
                                           document.content_type)
      if Formats.same_format?(from_ext, from_type, current_ext, current_type)
        return nil
      end

      source = original_format_label(from_ext, from_type)
      target = document_format_tag(document)
      _('{{source}}, converted to {{target}}',
        source: source, target: target).to_str
    end

    def normalized_conversion_extension(ext, content_type)
      value = ext.to_s.downcase.strip
      value = ".#{value}" if value.present? && !value.start_with?('.')
      return value if value.match?(Formats::SAFE_EXTENSION) && value != '.bin'

      derived = Formats.extension_for(content_type)
      return unless derived.match?(Formats::SAFE_EXTENSION) && derived != '.bin'

      derived
    end

    def original_format_label(ext, content_type)
      name = if ext && ORIGINAL_FORMAT_NAMES.key?(ext)
               _(ORIGINAL_FORMAT_NAMES[ext])
             elsif content_type.present? &&
                   FoiAttachment.content_type_names.key?(content_type)
               FoiAttachment.content_type_names[content_type]
             else
               declared = Formats.declared(content_type, "file#{ext}")
               declared == 'other' ? _('File') : _(Document::FORMAT_LABELS[declared])
             end
      ext.present? ? "#{name} (#{ext})" : name
    end

    def document_extent(version)
      return _('Table') if version.format == 'csv'

      count = version.page_count.to_i
      return unless count.positive?

      if version.format == 'spreadsheet'
        n_('{{count}} sheet', '{{count}} sheets', count, count: count)
      else
        n_('{{count}} page', '{{count}} pages', count, count: count)
      end
    end

    # Strips a leading kind_label prefix already shown above the title in lists.
    def document_display_title(document)
      title = document.title.to_s
      prefix = "#{document.kind_label}: "
      return title unless title.length > prefix.length &&
                          title.downcase.start_with?(prefix.downcase)

      title[prefix.length..].upcase_first
    end

    def sheet_preview(text, rows: 8, columns: 3)
      text.to_s.split("\n").first(rows).
        map { |line| line.split("\t", -1).first(columns) }
    end

    def numeric_cell?(cell)
      cell.to_s.strip.match?(/\A[-+£$]?\d[\d,]*(\.\d+)?%?\z/)
    end

    # Omits narrow boxes (< 10% width); they are summarised under the band.
    def document_box_tags(boxes)
      boxes.select { |x0, _, x1, _, _| x1 - x0 >= 0.1 }.first(30)
    end

    # Not module functions: these need the view (can?, link_to).
    public

    def document_text_line(text, pattern)
      parts = text.split(/(#{Regexp.escape(Reader::REDACTED)})/o).map do |part|
        if part == Reader::REDACTED
          next tag.span(part, class: 'document-redacted')
        end
        next part unless pattern

        pieces = []
        last = 0
        part.scan(pattern) do
          match = Regexp.last_match
          pieces << part[last...match.begin(0)] << tag.mark(match[0])
          last = match.end(0)
        end
        safe_join(pieces << part[last..])
      end
      safe_join(parts)
    end

    def document_row_path(document)
      return disclosure_document_path(document) if document.stage_in?(:listed)

      message = document.incoming_message
      if message && message.info_request_id == document.info_request_id &&
         can?(:publish_from_reply, message) &&
         can?(:publish_own_document, document)
        return publish_reply_check_path(
          url_title: message.info_request.url_title, message_id: message.id
        )
      end

      disclosure_manage_document_path(document)
    end

    def private_note(requester_id)
      private_note_for(requester_id, current_user)
    end

    def document_audience(document)
      return private_note(document.requester_id) unless document.listed?

      if current_user && document.requester_id == current_user.id
        _('Public: anyone can read it. Only you and the site’s admins can ' \
          'change it.')
      else
        _('Public: anyone can read it. Only the requester and the site’s ' \
          'admins can change it.')
      end
    end
  end
end
