# app/helpers/application_helper.rb:
# Methods added to this helper will be available to all views (i.e. templates)
# in the application.
#
# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

require 'languages'

module ApplicationHelper
  def turnstile_box(action)
    return unless Turnstile.configured?

    load_in_full!
    widget = tag.div(class: 'cf-turnstile',
                     data: { sitekey: Turnstile.site_key, action: action })
    script = javascript_include_tag(Turnstile::SCRIPT_URL,
                                    async: true, defer: true, nonce: true)
    widget + script
  end

  def page_flashes
    @page_flashes ||= render('general/flashes')
  end

  # Places flashes directly below a page's band so the layout omits its top
  # notice (#band_notice_placed?) and avoids splitting band from masthead.
  def band_notice
    return if band_notice_placed? || no_page_flashes?

    @band_notice_placed = true
    tag.div(page_flashes, class: 'band-flash',
                          data: { controller: 'flash-focus', uncached: true })
  end

  def band_notice_placed?
    @band_notice_placed == true
  end

  # Strip Rails development template comments so an empty flash box does not
  # cancel the page band's bottom margin.
  def no_page_flashes?
    page_flashes.to_str.gsub(/<!--.*?-->/m, '').blank?
  end

  def in_sign_in_dialog?
    controller.respond_to?(:in_sign_in_dialog?, true) &&
      controller.send(:in_sign_in_dialog?)
  end

  # Standard page-band header plus band_notice. Sign-in dialogs (no_chrome)
  # have no masthead and render flashes themselves; admin layouts do too.
  def page_band(title = @title, back: nil)
    return tag.h1(title) if in_sign_in_dialog?

    content_for :body_class, ' band-view '
    header = tag.header(class: 'page-band') do
      safe_join([
                  (tag.p(back, class: 'page-band__back') if back),
                  tag.h1(title, class: 'page-band__title')
                ])
    end
    return header if controller.is_a?(AdminController)

    safe_join([header, band_notice])
  end

  def back_to_account
    link_to _('Account'), show_user_path(url_name: current_user.url_name)
  end
  # URL generating functions are needed by all controllers (for redirects),
  # views (for links) and mailers (for use in emails), so include them into
  # all of all.
  include LinkToHelper

  # Some extra date and time formatters
  include DateTimeHelper

  # Site-wide access to configuration settings
  include ConfigHelper

  # Useful for sending emails
  include MailerHelper

  # Extra highlight helpers
  include HighlightHelper

  # Copied from error_messages_for in active_record_helper.rb
  def foi_error_messages_for(*params)
    options = params.last.is_a?(Hash) ? params.pop.symbolize_keys : {}
    objects = params.collect { |object_name| instance_variable_get("@#{object_name}") }.compact
    count   = objects.inject(0) { |sum, object| sum + object.errors.count }
    return if count.zero?

    html = {}
    [:id, :class].each do |key|
      if options.include?(key)
        value = options[key]
        html[key] = value unless value.blank?
      else
        html[key] = 'errorExplanation'
      end
    end

    error_messages = "".html_safe

    objects.each do |object|
      object.errors.each do |error|
        error_message = options[:full_message] ? error.full_message : error.message
        error_messages << content_tag(:li, h(error_message))
      end
    end

    content_tag(:div, content_tag(:ul, error_messages), html)
  end

  def locale_name(locale)
    LanguageNames.get_language_name(locale)
  end

  def admin_value(v)
    if v.nil?
      nil
    elsif v.is_a?(Time)
      admin_date(v)
    else
      h(v)
    end
  end

  def admin_date(date, ago: true, ago_only: false)
    ago_text = _('{{length_of_time}} ago', length_of_time: time_ago_in_words(date))
    text = ago_text if ago_only

    exact_date = I18n.l(date, format: "%e %B %Y %H:%M:%S")
    text ||= "#{exact_date} (#{ago_text})" if ago

    time_tag(date, text || exact_date, title: date)
  end

  def read_asset_file(asset_name)
    asset = Rails.application.assets.load_path.find(asset_name)
    raise Propshaft::MissingAssetError, asset_name unless asset

    asset.compiled_content.dup.force_encoding('utf-8')
  end

  # Public: Checks whether there is an active theme
  # Relies on the convention that themes prepend their view path to the
  # standard Rails view path in the view_paths array
  #
  # Returns a Boolean
  def theme_installed?
    view_paths.paths.count > 1
  end

  # Public: Whether the asset file is overridden in the current theme
  # Relies on the convention that themes prepend their view path to the
  # standard Rails view path in the view_paths array
  #
  # Returns a Boolean
  def theme_asset_exists?(asset_path)
    file_path =
      if theme_installed?
        view_paths.paths.first.to_s.
          gsub("/lib/views", "/app/assets/#{asset_path}")
      else
        view_paths.paths.first.to_s.
          gsub("/app/views", "/app/assets/#{asset_path}")
      end
    File.exist?(file_path)
  end

  # Note that if the admin interface is proxied via another server, we can't
  # rely on a session being shared between the front end and admin interface,
  # so need to check the status of the user.
  def is_admin?
    !session[:using_admin].nil? || (!@user.nil? && @user.is_admin?)
  end

  def cache_if_caching_fragments(key, *args)
    return yield unless AlaveteliConfiguration.cache_fragments && key

    locale_key = Array(key) << AlaveteliLocalization.locale
    cache(locale_key, *args) { yield }
  end

  def inside_layout(layout = 'application', &block)
    render inline: capture(&block), layout: "layouts/#{layout}"
  end

  def render_flash(message)
    message = { plain: message } if message.is_a?(String)
    render message.deep_symbolize_keys
  end

  # We only want to cache request lists that have a reasonable chance of not
  # expiring before they're requested again. Don't cache lists returned from
  # specific searches or anything except the first page of results, just the
  # first page of the default views
  def request_list_cache_key
    cacheable_param_list = %w[controller action view]
    return if params.empty? || (params.keys - cacheable_param_list).any?

    ["request-list", params[:view]]
  end

  def event_description(event)
    body_link = public_body_link_absolute(event.info_request.public_body)
    user_link = request_user_link_absolute(event.info_request)
    date = simple_date(event.created_at)
    case event.event_type
    when 'sent'
      _('Request sent to {{public_body_name}} by {{info_request_user}} on {{date}}.',
        public_body_name: body_link,
        info_request_user: user_link,
        date: date)
    when 'followup_sent'
      case event.calculated_state
      when 'internal_review'
        _('Internal review request sent to {{public_body_name}} by {{info_request_user}} on {{date}}.',
          public_body_name: body_link,
          info_request_user: user_link,
          date: date)
      when 'waiting_response'
        _('Clarification sent to {{public_body_name}} by {{info_request_user}} on {{date}}.',
          public_body_name: body_link,
          info_request_user: user_link,
          date: date)
      else
        _('Follow up sent to {{public_body_name}} by {{info_request_user}} on {{date}}.',
          public_body_name: body_link,
          info_request_user: user_link,
          date: date)
      end
    when 'response'
      _('Response by {{public_body_name}} to {{info_request_user}} on {{date}}.',
        public_body_name: body_link,
        info_request_user: user_link,
        date: date)
    when 'comment'
      _('Request to {{public_body_name}} by {{info_request_user}}. Annotated by {{event_comment_user}} on {{date}}.',
        public_body_name: body_link,
        info_request_user: user_link,
        event_comment_user: user_link_absolute(event.comment.user),
        date: date)
    end
  end

  def can_ask_the_eu?(code)
    WorldFOIWebsites.can_ask_the_eu?(code)
  end

  def controller?(*controllers)
    controllers.include?(params[:controller])
  end

  def action?(*actions)
    actions.include?(params[:action])
  end

  def site_wide_announcement
    @site_wide_announcement ||= Announcement.site_wide_for_user(
      current_user,
      session[:announcement_dismissals]
    ).first
  end

  def show_pro_upsell?(_user)
    false
  end

  # Omit file sizes below 1 MB to avoid noisy labels like "324 Bytes".
  LARGE_FILE_BYTES = 1.megabyte

  def large_file_size(bytes)
    number_to_human_size(bytes) if bytes.to_i >= LARGE_FILE_BYTES
  end

  # Full request-choice preservation arrives in B08 (RequestJourney::NavigationHelper).
  def request_journey_link_path(path, public_body: nil)
    path
  end

  def request_journey_hidden_fields(*)
    ''.html_safe
  end

  def request_journey_destination(section)
    section == 'authorities' ? list_public_bodies_default_path : frontpage_path
  end

  def request_journey_pro?
    false
  end
end
