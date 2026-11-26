class Ability
  # Visibility of a request, message, file or document source, independent of
  # viewer: :nobody < :admins < :requester (bounded by parent visibility).
  # Uses prominence allow-lists so unknown or missing values fail closed to
  # :admins.
  module RequesterVisible
    ORDER = %i[nobody admins requester].freeze

    REQUEST = %w[requester_only].freeze
    MESSAGE = %w[normal].freeze
    FILE = %w[public requester_only].freeze

    module_function

    def of(record)
      case record
      when nil then :nobody
      when InfoRequest then own(record)
      when IncomingMessage, OutgoingMessage then message(record)
      when FoiAttachment then file(record)
      when Disclosures::Document then source(record)
      else raise ArgumentError, "no visibility for #{record.class}"
      end
    end

    def requester?(record)
      of(record) == :requester
    end

    def nobody?(record)
      of(record) == :nobody
    end

    # Own prominence only, ignoring parents (takedown checks and follow-ups).
    def own(record)
      allowed = case record
                when InfoRequest then REQUEST
                when FoiAttachment then FILE
                else MESSAGE
                end
      allowed.include?(record.prominence) ? :requester : :admins
    end

    # Excludes in-progress spreadsheet checks (SpreadsheetHold), which are not
    # admin hides, so requesters can still delete the request while checks run.
    def hidden_by_admin?(record)
      level = case record
              when FoiAttachment then file(record, checking: false)
              when Disclosures::Document then source(record, checking: false)
              else of(record)
              end
      level != :requester
    end

    def least(*levels)
      levels.min_by { |level| ORDER.index(level) }
    end

    # SQL equivalent of requester? for named table aliases (outer-joined NULLs
    # fail closed). Omits SpreadsheetHold because spreadsheets never become
    # documents, which are the only file callers.
    def sql(request: nil, message: nil, file: nil)
      conditions = []
      conditions << "#{request}.prominence IN (#{list(REQUEST)})" if request
      conditions << "#{message}.prominence IN (#{list(MESSAGE)})" if message
      if file
        conditions << "#{file}.erased_at IS NULL"
        conditions << "#{file}.prominence IN (#{list(FILE)})"
      end
      raise ArgumentError, 'name at least one table' if conditions.empty?

      "(#{conditions.join(' AND ')})"
    end

    def message(record)
      request = record.info_request
      return :nobody unless request

      least(own(request), own(record))
    end

    def file(record, checking: true)
      return :nobody if record.erased?

      reply = record.incoming_message
      return :nobody unless reply&.info_request

      held = checking && Disclosures::SpreadsheetHold.waiting?(record)
      least(message(reply), own(record), held ? :admins : :requester)
    end

    # Document source visibility; drops to :admins if an admin moved the reply
    # to another request, and :nobody if the source attachment is gone.
    def source(document, checking: true)
      attachment = document.foi_attachment
      return :nobody unless attachment

      if document.request_deleted?
        return :nobody if attachment.erased?

        return own(attachment)
      end

      moved = attachment.incoming_message&.info_request_id !=
              document.info_request_id
      least(file(attachment, checking: checking),
            moved ? :admins : :requester)
    end

    # Values are hardcoded constants, so no DB connection is needed at boot.
    def list(values)
      values.map { |value| "'#{value}'" }.join(', ')
    end

    private_class_method :message, :file, :source, :list
  end
end
