module Authentication
  # Permit known local pages and numeric navigation fields only.
  class ReturnPath
    # Switches to '/pro/info_requests' in B03 PR 2 once the unified inbox is
    # enabled for every account.
    DEFAULT = '/'.freeze
    PATHS = [
      %r{\A/\z},
      %r{\A/help/[a-zA-Z0-9_-]+\z},
      %r{\A/change_request/new(?:/[a-zA-Z0-9_-]+)?\z},
      %r{\A/pro/(?:dashboard|info_requests(?:/new)?)\z},
      %r{\A/request/[a-zA-Z0-9_-]+
         (?:/(?:details|download|followups/new(?:/\d+)?))?\z}x,
      %r{\A/user/[a-zA-Z0-9_-]+(?:/(?:profile|requests))?\z},
      %r{\A/profile/(?:change_email|two_factor(?:/(?:new|backup_codes))?|
                      name/edit)\z}x,
      %r{\A/(?:new(?:/[a-zA-Z0-9_-]+)?|select_authority|documents|
                body/[a-zA-Z0-9_-]+)\z}x
    ].freeze

    def self.normalize(value)
      return DEFAULT unless plain_local?(value)

      uri = URI.parse(value)
      return DEFAULT unless bare_path?(uri)
      return DEFAULT unless PATHS.any? { |pattern| pattern.match?(uri.path) }

      pairs = URI.decode_www_form(uri.query.to_s)
      kept = pairs.select { |key, val| keep?(uri.path, key, val) }.uniq
      uri.path + (kept.empty? ? '' : "?#{URI.encode_www_form(kept)}")
    rescue URI::InvalidURIError, ArgumentError
      DEFAULT
    end

    private_class_method def self.plain_local?(value)
      return false unless value.is_a?(String) && value.bytesize <= 2048
      if value.match?(/[\\\x00-\x20\x7f]/) || !value.start_with?('/') ||
         value.start_with?('//')
        return false
      end

      true
    end

    private_class_method def self.bare_path?(uri)
      if uri.scheme || uri.host || uri.userinfo || uri.fragment ||
         uri.path.include?('%')
        return false
      end

      true
    end

    private_class_method def self.keep?(path, key, val)
      case key
      when 'draft_id'
        path == '/pro/info_requests/new' &&
          val.match?(/\A[1-9]\d{0,18}\z/)
      when 'step'
        path == '/pro/info_requests/new' &&
          %w[who subject write].include?(val)
      when 'page' then val.match?(/\A[1-9]\d{0,5}\z/)
      else false
      end
    end
  end
end
