# Admin CRUD for TopicGuide records linked to topic sources and questions.
class Admin::TopicGuidesController < AdminController
  include TranslatableParams

  helper_method :question_page_path

  def index
    @sources = sources
    @questions = Topics::Topic.all.flat_map do |topic|
      topic.questions.uniq(&:slug).map { |question| [topic, question] }
    end
    @guides = TopicGuide.includes(:translations).index_by do |guide|
      [guide.dataset_id, guide.topic_slug, guide.question_slug]
    end
  end

  def new
    @topic_guide = TopicGuide.new(new_params)
    @topic_guide.build_all_translations
  end

  def create
    @topic_guide = TopicGuide.new(topic_guide_params)
    if save_once(@topic_guide)
      redirect_to admin_topic_guides_path, notice: 'Guide saved.'
    else
      @topic_guide.build_all_translations
      render :new, status: :unprocessable_content
    end
  end

  def edit
    @topic_guide = TopicGuide.find(params[:id])
    @topic_guide.build_all_translations
  end

  def update
    @topic_guide = TopicGuide.find(params[:id])
    @topic_guide.assign_attributes(topic_guide_params)
    if save_once(@topic_guide)
      redirect_to admin_topic_guides_path, notice: 'Guide saved.'
    else
      @topic_guide.build_all_translations
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    TopicGuide.find(params[:id]).destroy
    redirect_to admin_topic_guides_path, notice: 'Guide deleted.'
  end

  private

  # Handle unique-index races when concurrent saves pass model validation.
  def save_once(guide)
    guide.save
  rescue ActiveRecord::RecordNotUnique
    guide.errors.add(:dataset_id, 'already has a guide')
    false
  end

  # Pick a nation where this question (and given source) is listed so the
  # preview shows the guide instead of redirecting to the topic.
  def question_page_path(topic, slug, source = nil)
    listed = Topics::Topic::NATIONS.keys.select do |key|
      topic.questions.any? { |each| each.slug == slug && each.useful_for?(key) }
    end
    nation = listed.find { |key| source_in?(topic, slug, source, key) } ||
             listed.first
    nation = nil if nation == 'england'
    topic_question_path(topic.slug, slug, nation: nation)
  end

  def source_in?(topic, slug, source, nation)
    source && topic.questions.any? do |each|
      each.slug == slug && each.useful_for?(nation) &&
        each.dataset_for(nation)&.id == source
    end
  end

  # Each source a question links to, with the questions it answers.
  def sources
    uses = Hash.new { |hash, id| hash[id] = [] }
    Topics::Topic.all.each do |topic|
      topic.questions.each do |question|
        dataset_ids(question).each { |id| uses[id] << [topic, question] }
      end
    end
    found = uses.filter_map do |id, list|
      dataset = Topics::Dataset.find(id) or next
      [dataset, list.uniq { |topic, question| [topic.slug, question.slug] }]
    end
    found.sort_by { |dataset, _| dataset.title.downcase }
  end

  def dataset_ids(question)
    ids = question.dataset
    (ids.is_a?(Hash) ? ids.values : Array(ids)).uniq
  end

  def new_params
    params.permit(:dataset_id, :question_key).to_h
  end

  def topic_guide_params
    translatable_params(
      params.require(:topic_guide),
      translated_keys: %i[locale title body],
      general_keys: %i[dataset_id question_key published]
    )
  end
end
