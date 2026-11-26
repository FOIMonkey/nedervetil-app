# controllers/application.rb:
# Parent class of all controllers in FOI site. Filters added to this controller
# apply to all controllers in the application. Likewise, all the methods added
# will be available for all controllers.
#
# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

class ApplicationController < ActionController::Base
  class PermissionDenied < StandardError
  end

  class RouteNotFound < StandardError
  end

  before_action :set_gettext_locale, :store_gettext_locale
  before_action :redirect_gettext_locale, :collect_locales

  protect_from_forgery if: :authenticated?, with: :exception
  before_action :verify_signed_out_origin, unless: :authenticated?

  # assign our own handler method for non-local exceptions
  rescue_from Exception, with: :render_exception

  # Deal with access denied errors from CanCan
  rescue_from CanCan::AccessDenied do |_exception|
    raise PermissionDenied
  end

  # Missing CSRF token or cross-origin POST: plain refusal, no error report.
  rescue_from ActionController::InvalidAuthenticityToken do
    render_form_refused(:unprocessable_content)
  end

  # Controllers omit `with:` on rate_limit so every 429 renders a friendly page.
  rescue_from ActionController::TooManyRequests do
    respond_to do |format|
      format.html do
        render template: 'general/too_many_attempts',
               status: :too_many_requests
      end
      format.any { head :too_many_requests }
    end
  end

  # Standard headers, footers and navigation for whole site
  layout "default"

  include FastGettext::Translation # make functions like _, n_, N_ etc available)
  include AlaveteliPro::PostRedirectHandler
  include ReadOnly
  include RobotsHeaders
  include TurboDrive
  include SigningIn

  # NOTE: a filter stops the chain if it redirects or renders something
  before_action :html_response
  before_action :authentication_check
  before_action :set_vary_header

  add_flash_types :error

  def set_vary_header
    response.headers['Vary'] = 'Cookie'
  end

  helper_method :anonymous_cache, :short_cache, :medium_cache, :long_cache
  def anonymous_cache(time)
    return if authenticated?

    headers['Cache-Control'] = "max-age=#{time}, public"
  end

  def short_cache
    anonymous_cache(60.seconds)
  end

  def medium_cache
    anonymous_cache(60.minutes)
  end

  def long_cache
    anonymous_cache(24.hours)
  end

  # This is an override of the method provided by gettext_i18n_rails.
  # AlaveteliLocalization.set_session_locale explicitly sets I18n.locale,
  # required due to the I18nProxy used in Rails to trigger the
  # lookup_context and expire the template cache
  def set_gettext_locale
    params_locale = params[:locale]

    if AlaveteliConfiguration.use_default_browser_language
      browser_locales = request.env['HTTP_ACCEPT_LANGUAGE'].to_s.split(',')
      browser_locales.map! { _1.split(';', 2)[0] }
    end

    AlaveteliLocalization.set_session_locale(
      params_locale, cookies[:locale], *browser_locales,
      AlaveteliLocalization.default_locale
    )

    # set response header informing the browser what language the page is in
    response.headers['Content-Language'] = I18n.locale.to_s
  end

  # Set the locale cookie only on multi-locale switches so public pages stay
  # CDN-cacheable; write user.locale only on change to preserve query cache.
  def store_gettext_locale
    locale = AlaveteliLocalization.locale.to_s
    if params[:locale].present? &&
       AlaveteliLocalization.available_locales.size > 1
      cookies[:locale] = locale
    end
    return unless current_user && current_user.read_attribute(:locale) != locale

    current_user.update_column(:locale, locale)
  end

  def redirect_gettext_locale
    # redirect to remove locale params if present
    redirect_to current_path_without_locale if params[:locale]
  end

  # Help work out which request causes RAM spike.
  # http://www.codeweblog.com/rails-to-monitor-the-process-of-memory-leaks-skills/
  # This shows the memory use increase of the Ruby process due to the request.
  # Since Ruby never returns memory to the OS, if the existing process previously
  # served a larger request, this won't show any consumption for the later request.
  # Ruby also grabs memory from the OS in variously sized jumps, so the extra
  # consumption of a request shown by this function will only appear in such
  # jumps.
  #
  # To find things that are using causing LOTS of peak memory, then do something like:
  # egrep "CONSUME MEMORY: [0-9]{7} KB" production.log
  around_action :record_memory
  def record_memory
    record_memory = AlaveteliConfiguration.debug_record_memory
    if record_memory
      logger.info "Processing request for #{request.url} with Rails process #{Process.pid}"
      File.read("/proc/#{Process.pid}/status").match(/VmRSS:\s+(\d+)/)
      rss_before_action = $1.to_i
      yield
      File.read("/proc/#{Process.pid}/status").match(/VmRSS:\s+(\d+)/)
      rss_after_action = $1.to_i
      logger.info("PID: #{Process.pid}\tCONSUME MEMORY: #{rss_after_action - rss_before_action} KB\tNow: #{rss_after_action} KB\t#{request.url}")
    else
      yield
    end
  end

  def render_exception(exception)
    # In development let Rails handle the exception with its stack trace
    # templates.
    raise exception if Rails.application.config.consider_all_requests_local

    @exception_backtrace = exception.backtrace.join("\n")
    @exception_class = exception.class.to_s
    @exception_message = exception.message
    case exception
    when ActiveRecord::RecordNotFound, RouteNotFound, WillPaginate::InvalidPage
      @status = 404
      sanitize_path(params)
    when PermissionDenied
      @status = 403
    when ActionController::UnknownFormat
      @status = 406
    else
      message = "\n#{@exception_class} (#{@exception_message}):\n"
      backtrace = Rails.backtrace_cleaner.clean(exception.backtrace, :silent)
      message << "  " << backtrace.join("\n  ")
      Rails.logger.fatal("#{message}\n\n")
      if send_exception_notifications?
        ExceptionNotifier.notify_exception(exception, env: request.env)
      end
      @status = 500
    end
    respond_to do |format|
      format.html { render template: "general/exception_caught", status: @status }
      format.any { head @status }
    end
  end

  def render_hidden(template='request/hidden', opts = {})
    # An embargoed is totally hidden - no indication that anything exists there
    # to see
    raise ActiveRecord::RecordNotFound if @info_request && @info_request.embargo

    response_code = opts.delete(:response_code) { 403 } # forbidden
    options = { template: template, status: response_code }.merge(opts)

    respond_to do |format|
      format.html { render(options) }
      format.any { head response_code }
    end
    false
  end

  # A helper method to set @in_pro_area, for controller actions which are
  # used in both a pro and non-pro context and depend on the :pro parameter
  # to know which one they're displaying.
  # Intended to be used as a before_action, see RequestController for example
  # usage.
  def set_in_pro_area
    @in_pro_area = params[:pro] == "1" && current_user.present?
  end

  private

  def render_form_refused(status)
    respond_to do |format|
      format.html { render template: 'general/form_refused', status: status }
      format.any { head status }
    end
  end

  def failed_submit_status
    request.get? || request.head? ? :ok : :unprocessable_content
  end

  def html_response
    respond_to :html
  end

  # Convert URL name for sort by order, to Xapian query
  def order_to_sort_by(sortby)
    if sortby.nil?
      [nil, nil]
    elsif sortby == 'newest'
      ['created_at', true]
    elsif sortby == 'described'
      ['described_at', true] # use this for some RSS
    elsif sortby == 'relevant'
      [nil, nil]
    else
      raise "Unknown sort order " + @sortby
    end
  end

  # Function for search
  def perform_search(models, query, sortby, collapse, per_page = 25, this_page = nil)
    @query = query
    @sortby = sortby

    # Work out sorting method
    order, ascending = order_to_sort_by(@sortby)

    # Perform the search
    @per_page = per_page
    @page = this_page || get_search_page_from_params

    Search.search(@query, models: models, sort_by: order,
                          sort_ascending: ascending,
                          collapse_by: collapse).
      results(page: @page, per_page: @per_page)
  end

  def perform_track_search(track_thing)
    per_page = 25
    order, = order_to_sort_by(track_thing.params[:feed_sortby])
    offset = (get_search_page_from_params - 1) * per_page
    track_thing.matches(sort_by: order, limit: per_page,
                        offset: offset)
  end

  def get_search_page_from_params
    page = (params[:page] || "1").to_i
    page = 1 if page < 1
    page
  end

  def typeahead_search(query, options)
    @page = get_search_page_from_params
    @per_page = options[:per_page] || 25

    Search.typeahead(query, model: options[:model],
                            exclude_tags: options[:exclude_tags] || []).
      results(page: @page, per_page: @per_page)
  end

  # Store last visited pages, for contact form; but only for logged in users, as otherwise this breaks caching
  def set_last_request(info_request)
    return unless authenticated?

    cookies[:last_request_id] = info_request.id
    cookies[:last_body_id] = nil
  end

  def set_last_body(public_body)
    return unless authenticated?

    cookies[:last_request_id] = nil
    cookies[:last_body_id] = public_body.id
  end

  def country_from_ip
    return AlaveteliGeoIP.country_code_from_ip(user_ip) if user_ip

    AlaveteliConfiguration.iso_country_code
  end

  def blocked_ip?
    return false if country_from_ip == AlaveteliConfiguration.iso_country_code

    restricted = Array(AlaveteliConfiguration.restricted_countries.split(' '))
    permitted = restricted.map { |c| c.delete_prefix!('!') }.compact

    if permitted.any?
      !permitted.include?(country_from_ip)
    else
      restricted.include?(country_from_ip)
    end
  end

  def user_ip
    request.remote_ip
  rescue ActionDispatch::RemoteIp::IpSpoofAttackError
    nil
  end

  # URL Encode the path parameter for use in render_exception
  #
  # params - the params Hash
  #
  # Returns a Hash
  def sanitize_path(params)
    params.merge!(path: Rack::Utils.escape(params[:path])) if params.key?(:path)
  end

  # Collect the current and available locales for the locale switcher
  #
  # Returns a Hash
  def collect_locales
    @locales = { current: AlaveteliLocalization.locale, available: [] }
    AlaveteliLocalization.available_locales.each do |possible_locale|
      if possible_locale == AlaveteliLocalization.locale
        @locales[:current] = possible_locale
      else
        @locales[:available] << possible_locale
      end
    end
  end

  # URL generating functions are needed by all controllers (for redirects),
  # views (for links) and mailers (for use in emails), so include them into
  # all of all.
  include LinkToHelper

  # Site-wide access to configuration settings
  include ConfigHelper

  include HashableParams

  include PrivateArchive

  # Run the privacy gate ahead of other callbacks once locale and user are set.
  # prepend_before_action runs bottom-up, so a subclass's prepend_before_action
  # runs before the gate and must not look up request-named records.
  prepend_before_action :private_archive_policy
  prepend_before_action :authentication_check
  prepend_before_action :collect_locales
  prepend_before_action :set_gettext_locale
  after_action :private_archive_no_store
end
