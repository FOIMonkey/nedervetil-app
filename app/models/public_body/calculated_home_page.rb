# Guess the home page based on the request email domain.
module PublicBody::CalculatedHomePage
  extend ActiveSupport::Concern

  class_methods do
    def excluded_calculated_home_page_domains
      @excluded_calculated_home_page_domains ||= Domains.webmail_providers
    end

    def excluded_calculated_home_page_domains=(domains)
      @excluded_calculated_home_page_domains = domains
    end
  end

  def calculated_home_page
    @calculated_home_page ||= calculated_home_page!
  end

  private

  # The known home page as a web address, or a guess if none is known. A
  # stored home page that isn't a web address (HttpUrl), from before it was
  # checked, gives nil: no link, and no guess either.
  def calculated_home_page!
    return HttpUrl.with_default_scheme(home_page) if home_page.present?

    guess_home_page
  end

  # Guess the home page from the request address email domain.
  def guess_home_page
    return unless request_email_domain
    return if excluded_calculated_home_page_domain?(request_email_domain)

    "https://www.#{request_email_domain}"
  end

  def excluded_calculated_home_page_domain?(domain)
    self.class.excluded_calculated_home_page_domains.include?(domain)
  end
end
