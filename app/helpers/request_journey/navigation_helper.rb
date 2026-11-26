module RequestJourney
  # Carries explicit request_choice URL context without DB lookups; controllers
  # overlay page-specific values via request_journey_page_choices.
  module NavigationHelper
    # Themes may pre-set @request_journey_pro; otherwise true when signed in.
    def request_journey_pro?
      return @request_journey_pro if defined?(@request_journey_pro)

      @request_journey_pro = current_user.present?
    end

    # Overridden via controller helper_method to merge page choices (nil drops
    # a key; :journey uses string keys).
    def request_journey_page_choices
      {}
    end

    # Overridden via helper_method to return { id:, step: } for unsaved forms.
    def request_journey_form; end

    def request_journey_choices
      return @request_journey_choices.dup if defined?(@request_journey_choices)

      choices = request_journey_address_choices.
        deep_merge(request_journey_page_choices)
      # Checked again, because a holder has to belong to the page's topic.
      journey = RequestJourney::Context.new(choices.delete(:journey)).values
      @request_journey_choices =
        choices.merge(journey: journey.presence).compact
      @request_journey_choices.dup
    end

    def make_request_path(body = nil)
      unless request_journey_pro?
        return new_request_to_body_path(url_name: body.url_name) if body

        return select_authority_path
      end

      choices = request_journey_choices
      choices[:public_body] = body.url_name if body
      new_alaveteli_pro_info_request_path(choices)
    end

    def request_journey_destination(destination)
      return make_request_path if destination == 'request'

      options = if request_journey_pro?
                  { request_choice: request_journey_choices.presence }.compact
                else
                  {}
                end
      case destination
      when 'home' then alaveteli_pro_dashboard_path(options)
      when 'about' then help_about_path(options)
      when 'topics' then topics_path(options)
      when 'documents' then disclosure_documents_path(options)
      when 'authorities' then authority_groups_path(options)
      end
    end

    # Submits the active form natively (even from outside it, without JS) so
    # unsaved fields survive navigation.
    def request_journey_nav(label, destination, **attributes)
      form = request_journey_form
      if form
        name, value = if destination == 'request'
                        ['journey_step', form[:step]]
                      else
                        ['journey_destination', destination]
                      end
        button_tag label, **attributes.merge(type: 'submit',
                                             form: form[:id],
                                             name: name,
                                             value: value,
                                             class: 'request-nav-action')
      else
        link_to label, request_journey_destination(destination), **attributes
      end
    end

    def request_journey_hidden_fields
      return unless request_journey_pro? && params[:request_choice].present?

      fields = request_journey_choices.map do |key, value|
        if key == :journey
          safe_join(value.map do |name, choice|
            hidden_field_tag "request_choice[journey][#{name}]",
                             choice,
                             id: nil
          end)
        else
          hidden_field_tag "request_choice[#{key}]", value, id: nil
        end
      end
      safe_join(fields)
    end

    def request_journey_link_path(path, public_body: nil)
      unless request_journey_pro? && path.start_with?('/') &&
             !path.start_with?('//')
        return path
      end

      choices = request_journey_choices
      choices[:public_body] = public_body.url_name if public_body
      return path if choices.empty?

      uri = URI.parse(path)
      uri.query = Rack::Utils.parse_nested_query(uri.query).
        merge('request_choice' => choices).to_query
      uri.to_s
    end

    private

    def request_journey_address_choices
      raw = request_journey_address_params
      choices = {}
      { 'subject' => 200, 'question' => Topics::Suggestions::MAX_TEXT }.
        each do |key, length|
          next unless raw[key].is_a?(String)

          choices[key.to_sym] = raw[key].strip.first(length).presence
        end
      %w[draft_id from].each do |key|
        choices[key.to_sym] = raw[key] if raw[key].to_s.match?(/\A\d+\z/)
      end
      if raw['public_body'].is_a?(String) &&
         raw['public_body'].match?(/\A[\w-]{1,200}\z/)
        choices[:public_body] = raw['public_body']
      end
      choices.merge(journey: RequestJourney::Context.new(raw['journey']).values)
    end

    def request_journey_address_params
      raw = params[:request_choice]
      return {} unless raw.respond_to?(:permit)

      raw.permit(:subject, :question, :public_body, :draft_id, :from,
                 journey: %i[topic nation holder]).to_h
    end
  end
end
