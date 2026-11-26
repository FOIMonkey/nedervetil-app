# The topic pages, each with its holders, questions, published sources and
# other routes. A topic's edit page holds its own form and its rows' lists.
# One a topic guide names can't be deleted.
class Admin::TopicPagesController < AdminController
  include Admin::TopicContentEditing

  FIELDS = {
    title: :text, summary: :text, position: :text, search: :text,
    elsewhere_heading: :text, titles: :nation_map, documents: :lines,
    refused: :lines
  }.freeze

  before_action :find_topic_page, only: %i[edit update destroy]

  def index
    @topic_pages = TopicPage.includes(:holders, :questions, :sources, :routes).
                   order(:position, :slug)
  end

  def new
    @topic_page = TopicPage.new(position: TopicPage.maximum(:position).to_i + 1)
  end

  def create
    @topic_page = TopicPage.new(
      content_params(:topic_page, FIELDS.merge(slug: :text))
    )
    if @topic_page.save
      redirect_to edit_admin_topic_page_path(@topic_page), notice: SAVED
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @topic_page.update(content_params(:topic_page, FIELDS))
      redirect_to edit_admin_topic_page_path(@topic_page), notice: SAVED
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    if @topic_page.destroy
      redirect_to admin_topic_pages_path, notice: DELETED
    else
      redirect_to edit_admin_topic_page_path(@topic_page),
                  flash: { error: @topic_page.errors.full_messages.to_sentence }
    end
  end

  private

  def find_topic_page
    @topic_page = TopicPage.find_by!(slug: params[:id])
  end
end
