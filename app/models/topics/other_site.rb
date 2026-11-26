module Topics
  # Another FOI site (OTHER_FOI_SITE_NAME, OTHER_FOI_SITE_URL) for
  # authorities that aren't listed here and for visitors who can't have an
  # account; none by default.
  module OtherSite
    module_function

    def name
      AlaveteliConfiguration.other_foi_site_name.presence
    end

    def url(query = nil)
      base = AlaveteliConfiguration.other_foi_site_url.presence
      return unless name && base

      uri = URI.parse(base)
      return unless uri.is_a?(URI::HTTP) && uri.host.present?

      return uri.to_s if query.blank?

      uri.query = URI.encode_www_form(URI.decode_www_form(uri.query.to_s) +
                                      [['query', query]])
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    # Past requests on the other site, if it's an Alaveteli like this one.
    def search_url(query)
      base = url
      return unless base && query.present?

      uri = URI.parse(base)
      uri.path = "/search/#{ERB::Util.url_encode(query)}/requests"
      uri.query = nil
      uri.to_s
    end

    def link?(url)
      !!(base = self.url) && url.to_s.start_with?(base)
    end
  end
end
