# The datasets that answer topic questions. One a question or a topic guide
# names can't be deleted.
class Admin::TopicDatasetsController < AdminController
  include Admin::TopicContentEditing

  FIELDS = {
    publisher: :text, title: :text, table_title: :text, answers: :text,
    url: :text, kind: :text, status: :text, geography: :text,
    nations: :nations, coverage: :text, frequency: :text, area_url: :text,
    area_codes: :lines, api: :text
  }.freeze

  before_action :find_topic_dataset, only: %i[edit update destroy]

  def index
    @query = params[:query].to_s.strip
    @topic_datasets = matching(@query).order(:publisher, :title)
    @uses = TopicQuestion.pluck(:dataset).flat_map { |map| map.values.uniq }.
            tally
  end

  def new
    @topic_dataset = TopicDataset.new
  end

  def create
    @topic_dataset = TopicDataset.new(
      content_params(:topic_dataset, FIELDS.merge(key: :text))
    )
    if @topic_dataset.save
      redirect_to admin_topic_datasets_path, notice: SAVED
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
    load_used_by_questions
  end

  def update
    if @topic_dataset.update(content_params(:topic_dataset, FIELDS))
      redirect_to admin_topic_datasets_path, notice: SAVED
    else
      load_used_by_questions
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    if @topic_dataset.destroy
      redirect_to admin_topic_datasets_path, notice: DELETED
    else
      error = @topic_dataset.errors.full_messages.to_sentence
      redirect_to edit_admin_topic_dataset_path(@topic_dataset),
                  flash: { error: error }
    end
  end

  private

  def find_topic_dataset
    @topic_dataset = TopicDataset.find(params[:id])
  end

  def load_used_by_questions
    @used_by_questions = TopicQuestion.includes(:topic_page).select do |q|
      q.dataset.value?(@topic_dataset.key)
    end
  end

  # Each word in the title, publisher or key.
  def matching(query)
    query.split.reduce(TopicDataset.all) do |scope, word|
      like = "%#{TopicDataset.sanitize_sql_like(word)}%"
      scope.where('title ILIKE :like OR publisher ILIKE :like OR ' \
                  'key ILIKE :like', like: like)
    end
  end
end
