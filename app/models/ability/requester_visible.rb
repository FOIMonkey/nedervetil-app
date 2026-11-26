class Ability
  # Visibility of a request, message or file, independent of viewer:
  # :nobody < :admins < :requester (bounded by parent visibility).
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

    def hidden_by_admin?(record)
      of(record) != :requester
    end

    def least(*levels)
      levels.min_by { |level| ORDER.index(level) }
    end

    # SQL equivalent of requester? for named table aliases (outer-joined NULLs
    # fail closed).
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

    def file(record)
      return :nobody if record.erased?

      reply = record.incoming_message
      return :nobody unless reply&.info_request

      least(message(reply), own(record))
    end

    # Values are hardcoded constants, so no DB connection is needed at boot.
    def list(values)
      values.map { |value| "'#{value}'" }.join(', ')
    end

    private_class_method :message, :file, :list
  end
end
