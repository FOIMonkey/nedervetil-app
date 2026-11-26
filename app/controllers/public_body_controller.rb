# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

require 'tempfile'

# Serves the public authority directory, category/tag listings, CSV export and
# typeahead search; /body/:url_name requests are handled by PrivateArchive.
class PublicBodyController < ApplicationController
  skip_before_action :html_response, only: [:show, :list_all_csv]
  skip_before_action :redirect_gettext_locale, only: :show
  helper_method :request_journey_page_choices

  MAX_RESULTS = 500

  # Kept for the route; PrivateArchive#private_archive_body_page intercepts
  # /body/:url_name before this action runs.
  def show; end

  def list
    long_cache

    @tag = params[:tag] || 'all'
    @tag = @tag.upcase if @tag.scan(/./mu).size == 1

    @country_code = AlaveteliConfiguration.iso_country_code
    @locale = AlaveteliLocalization.locale

    AlaveteliLocalization.with_locale(@locale) do
      @public_bodies = PublicBody.visible.
                                  with_tag(@tag).
                                  with_query(params[:public_body_query], @tag).
                                  preload(:translations, :tags).
                                  paginate(page: params[:page], per_page: 100)

      @description =
        if @tag == 'all'
          n_('Found {{count}} public authority',
             'Found {{count}} public authorities',
             @public_bodies.total_entries,
             count: @public_bodies.total_entries)
        elsif @tag.size == 1
          n_('Found {{count}} public authority beginning with ' \
             '‘{{first_letter}}’',
             'Found {{count}} public authorities beginning with ' \
             '‘{{first_letter}}’',
             @public_bodies.total_entries,
             count: @public_bodies.total_entries,
             first_letter: @tag)
        else
          @category = PublicBody.category_list.find_by(category_tag: @tag)
          if @category.nil?
            n_('Found {{count}} public authority matching the tag ' \
               '‘{{tag_name}}’',
               'Found {{count}} public authorities matching the tag ' \
               '‘{{tag_name}}’',
               @public_bodies.total_entries,
               count: @public_bodies.total_entries,
               tag_name: @tag)
          else
            n_('Found {{count}} public authority in the category ' \
               '‘{{category}}’',
               'Found {{count}} public authorities in the category ' \
               '‘{{category}}’',
               @public_bodies.total_entries,
               count: @public_bodies.total_entries,
               category: @category.title)
          end
        end

      render template: 'public_body/list'
    end
  end

  # Used so URLs like /local/islington work, for use e.g. writing to a local
  # paper.
  def list_redirect
    @tag = params[:tag]
    redirect_to list_public_bodies_url(tag: @tag)
  end

  # GET /body/all-authorities.csv
  #
  # Returns all public bodies (except for the internal admin authority) as CSV
  def list_all_csv
    output = Rails.root.join('cache', 'all-authorities.csv')
    return head :no_content unless output.exist?

    # Send the file
    send_file(output,
              type: 'text/csv; charset=utf-8; header=present',
              filename: File.basename(output),
              disposition: 'attachment',
              encoding: 'utf8')
  end

  # Type ahead search
  def search_typeahead
    query = params[:query]
    return head :bad_request unless query

    @request_results = typeahead_search(query, model: PublicBody)
    render :search_typeahead, layout: false
  end

  private

  # @public_body is set by PrivateArchive#private_archive_body_page.
  def request_journey_page_choices
    return {} unless @public_body

    { public_body: @public_body.url_name }
  end
end
