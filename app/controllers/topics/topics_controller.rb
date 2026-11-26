module Topics
  # Serves public topic guides, question pages and authority lists. Never
  # cached because pages display published documents that may be withdrawn.
  class TopicsController < Disclosures::BaseController
    LATEST = 4

    # Matches legacy ?step=q-<index> query params redirected by #show.
    LEGACY_STEP = /\Aq-(\d+)\z/

    before_action :find_topic, except: :index
    helper_method :request_journey_page_choices

    def index
      @topics = Topic.all
      @title = _('What do you want to know?')
      @nation = nation
    end

    def show
      if (target = legacy_target)
        return redirect_to target, status: :moved_permanently
      end

      @title = "#{@topic.title_for(@nation)}: #{_(Topic::NATIONS[@nation])}"
    end

    def question
      @entry = @guide.entry(params[:question].to_s)
      unless @entry
        raise ActiveRecord::RecordNotFound unless
          @topic.question(params[:question].to_s)

        flash[:notice] = _('That question isn’t listed for {{nation}}.',
                           nation: _(Topic::NATIONS[@nation]))
        return redirect_to topic_path(@topic.slug, nation: place)
      end

      @title = "#{@entry.question.text}: #{_(Topic::NATIONS[@nation])}"
    end

    def holders
      @title = "#{_('Who holds it')}: #{@topic.title_for(@nation)}"
    end

    private

    def request_journey_page_choices
      return {} unless @topic

      { journey: { 'topic' => @topic.slug, 'nation' => @nation } }
    end

    def find_topic
      @topic = Topic.find(params[:slug].to_s) or
        raise ActiveRecord::RecordNotFound
      @nation = nation
      @topics = Topic.all
      @guide = Guide.new(@topic, @nation)
    end

    def legacy_target
      step = params[:step].to_s
      return unless params[:view] == 'all' || params.key?(:step)

      entry = (match = step.match(LEGACY_STEP)) && @guide.entries[match[1].to_i]
      if entry
        topic_question_path(@topic.slug, entry.slug, nation: place)
      elsif step.start_with?('other')
        topic_holders_path(@topic.slug, nation: place)
      elsif %w[own fix].include?(step)
        topics_path(step: step, nation: place)
      else
        topic_path(@topic.slug, nation: place)
      end
    end

    def nation
      Topic::NATIONS.key?(params[:nation]) ? params[:nation] : 'england'
    end

    def place
      @nation unless @nation == 'england'
    end
  end
end
