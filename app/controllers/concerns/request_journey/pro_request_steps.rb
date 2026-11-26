module RequestJourney
  # Step-by-step inbox request flow (who, subject, write, review) mixed into
  # AlaveteliPro::InfoRequestsController.
  module ProRequestSteps
    extend ActiveSupport::Concern

    # Form IDs for editable steps (review has no unsaved fields).
    STEP_FORMS = { who: 'authority_form',
                   subject: 'subject_form',
                   write: 'write_form' }.freeze

    included do
      helper_method :request_journey_page_choices, :request_journey_form
    end

    private

    # Overrides URL choices for RequestJourney::NavigationHelper; nil keys
    # clear values no longer present on the form.
    def request_journey_page_choices
      return {} unless @info_request

      { subject: (@subject || @info_request.title).presence,
        public_body: @info_request.public_body&.url_name,
        draft_id: (@draft_info_request.id if @draft_info_request&.persisted?),
        question: params[:question].presence,
        from: @copied&.id,
        journey: { 'topic' => nil, 'nation' => nil, 'holder' => nil }.
          merge(@journey_context || {}) }
    end

    # Active form submitted by the nav menu to preserve unsaved fields.
    def request_journey_form
      return if @info_request.nil? || @info_request.persisted?

      step = @step || :write
      { id: STEP_FORMS[step], step: step.to_s } if STEP_FORMS.key?(step)
    end

    def start_journey
      @info_request.public_body = @public_body if @public_body
      check_public_body_is_requestable
      return if performed?

      set_journey_context
      if params[:from].present?
        @copied = current_user.info_requests.find_by(id: params[:from])
      end
      @subject = subject_from_params
      if %w[home about topics documents authorities].
         include?(params[:journey_destination])
        choices = helpers.request_journey_choices
        return redirect_to destination_path(params[:journey_destination],
                                            choices)
      end
      @step = journey_step
      prepare_step
      return unless @step == :write

      start_letter
      persist_initial_letter unless @draft_info_request.persisted?
    end

    def subject_from_params
      subject =
        if params.key?(:subject) || params.key?(:question)
          (params[:subject] || params[:question]).to_s.strip.first(200)
        else
          @info_request.title.presence || @copied&.title.to_s
        end
      if params.key?(:question) && !params.key?(:subject)
        subject = RequestLetter.subject(subject)
      end
      subject
    end

    def prepare_step
      if @step == :who
        @authority_query = params[:query].to_s.strip.first(200)
        if @authority_query.present?
          @authority_results = authority_results(@authority_query)
        end
      elsif @step == :subject && params[:check].present? && @subject.present?
        @suggestions =
          RequestJourney::Suggestions.new(@info_request.public_body, @subject)
        unless [@suggestions.questions, @suggestions.documents,
                @suggestions.releases].any?(&:any?)
          @step = :write
        end
      end
    end

    def set_journey_context
      @journey_context = RequestJourney::Context.new(
        params[:journey] || @draft_info_request&.journey_context || {}
      ).values
    end

    def journey_step
      return params[:journey_step].to_sym if step_named?
      return :who if authority_needed?
      return :subject if subject_needed?
      return :write if ready_to_write?

      :subject
    end

    def step_named?
      %w[who subject write].include?(params[:journey_step]) &&
        (@info_request.public_body || params[:journey_step] == 'who')
    end

    def authority_needed?
      params[:change].present? || params[:step] == 'who' ||
        @info_request.public_body.nil?
    end

    def subject_needed?
      params[:step] == 'subject' || @subject.blank? ||
        params[:check].present?
    end

    def ready_to_write?
      params[:step] == 'write' || params[:go].present? ||
        @draft_info_request&.persisted? || @copied
    end

    def start_letter
      @info_request.title = @subject
      return if @draft_info_request&.persisted?

      middle =
        if @copied
          old = @copied.outgoing_messages.first&.body.to_s
          RequestLetter.split(old,
                              @copied.public_body.name,
                              current_user.name) || old
        else
          # Carry over a topic question if given; never prefill from subject.
          params[:question].to_s.strip.first(Topics::Suggestions::MAX_TEXT)
        end
      @outgoing_message.body = RequestLetter.join(
        middle,
        @info_request.public_body.name,
        current_user.name
      )
    end

    # The edit form always carries an owned draft ID. An expired session can
    # therefore return to that draft without replaying a submitted form.
    def persist_initial_letter
      @draft_info_request = current_user.draft_info_requests.create!(
        title: @info_request.title, body: @outgoing_message.body,
        public_body: @info_request.public_body,
        journey_context: @journey_context
      )
      redirect_to new_alaveteli_pro_info_request_path(
        draft_id: @draft_info_request.id, step: 'write', from: @copied&.id
      )
    end

    def save_letter
      request_params = params[:info_request]
      unless request_params.respond_to?(:key?) &&
             params[:outgoing_message].respond_to?(:key?)
        return
      end

      draft = if params[:draft_id].present?
                current_user.draft_info_requests.find(params[:draft_id])
              else
                current_user.draft_info_requests.new
              end
      @draft_info_request = draft
      set_journey_context
      body = PublicBody.find_by(id: request_params[:public_body_id])
      letter = params[:outgoing_message]
      text = if letter.key?(:letter)
               RequestLetter.join(letter[:letter],
                                  body&.name,
                                  current_user.name)
             else
               letter[:body].to_s
             end
      draft.assign_attributes(title: request_params[:title].to_s,
                              public_body: body,
                              body: text,
                              journey_context: @journey_context)
      draft.save!(validate: false)
      params[:draft_id] = draft.id.to_s
      redirect_after_save(draft)
    end

    def redirect_after_save(draft)
      if params[:review].present?
        redirect_to preview_new_alaveteli_pro_info_request_path(
          draft_id: draft.id
        )
      elsif params[:journey_step] == 'publications'
        redirect_to new_alaveteli_pro_info_request_path(
          draft_id: draft.id,
          step: 'subject',
          check: 1
        )
      elsif %w[who subject write].include?(params[:journey_step])
        redirect_to new_alaveteli_pro_info_request_path(
          draft_id: draft.id,
          step: params[:journey_step]
        )
      elsif %w[home about topics documents authorities].
            include?(params[:journey_destination])
        redirect_to destination_path(params[:journey_destination],
                                     { draft_id: draft.id })
      elsif params[:save_draft].present?
        redirect_to new_alaveteli_pro_info_request_path(draft_id: draft.id),
                    notice: _('Draft saved.')
      end
    end

    def destination_path(destination, choices)
      options = { request_choice: choices.presence }.compact
      case destination
      when 'home' then alaveteli_pro_dashboard_path(options)
      when 'about'
        # The theme's help pack, when it has one.
        if HelpSite.pack?
          help_home_path(options)
        else
          help_about_path(options)
        end
      when 'topics' then topics_path(options)
      when 'documents' then disclosure_documents_path(options)
      when 'authorities' then authority_groups_path(options)
      end
    end

    def authority_results(query)
      # Pre-filter requestable and topic scopes before LIMIT; is_requestable?
      # remains the final check (accounting for override addresses).
      ids = typeahead_search(query,
                             model: PublicBody,
                             exclude_tags: %w[defunct not_apply]).
        results.map { |result| result[:model].id }
      scope = PublicBody.visible.
              with_translations(AlaveteliLocalization.locale).
              where('public_body_translations.name ILIKE :q OR ' \
                    'public_body_translations.short_name ILIKE :q OR ' \
                    'public_bodies.id IN (:ids)',
                    q: "%#{PublicBody.sanitize_sql_like(query)}%",
                    ids: ids).
              not_defunct.foi_applies.
              where("COALESCE(public_body_translations.request_email, '') " \
                    "NOT IN ('', 'blank')")
      if (holder = @journey_context['holder'])
        scope = scope.where(id: PublicBody.with_tag(holder).select(:id))
      end
      nation = @journey_context['nation']
      if nation == 'england'
        (Topics::Topic::NATIONS.keys - ['england']).
          flat_map { |other| Topics::Holds.nation_tags(other) }.
          each do |tag|
            scope = scope.where.not(id: PublicBody.with_tag(tag).select(:id))
          end
      elsif nation
        scope = scope.where(
          id: Topics::Holds.nation_tags(nation).
            map { |tag| PublicBody.with_tag(tag) }.reduce(:or).select(:id)
        )
      end
      scope.order('public_body_translations.name').limit(20).
        includes(:tags, :translations).to_a.select(&:is_requestable?)
    end
  end
end
