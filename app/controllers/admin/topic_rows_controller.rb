# Base CRUD controller for ordered child rows of a TopicPage; subclasses
# define ROWS, FIELDS and optional CREATE_FIELDS.
class Admin::TopicRowsController < AdminController
  include Admin::TopicContentEditing

  CREATE_FIELDS = {}.freeze

  before_action :find_rows
  before_action :find_row, only: %i[edit update destroy]

  def new
    @row = @rows.build(position: (@rows.maximum(:position) || 0) + 1)
  end

  def create
    @row = @rows.build(row_params(self.class::CREATE_FIELDS))
    if @row.save
      redirect_to edit_admin_topic_page_path(@topic_page), notice: SAVED
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @row.update(row_params)
      redirect_to edit_admin_topic_page_path(@topic_page), notice: SAVED
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    if @row.destroy
      redirect_to edit_admin_topic_page_path(@topic_page), notice: DELETED
    else
      redirect_to [:edit, :admin, @topic_page, @row],
                  flash: { error: @row.errors.full_messages.to_sentence }
    end
  end

  private

  def find_rows
    @topic_page = TopicPage.find_by!(slug: params[:topic_page_id])
    @rows = @topic_page.public_send(self.class::ROWS)
  end

  def find_row
    @row = @rows.find(params[:id])
  end

  def row_params(extra = {})
    content_params(@rows.klass.model_name.param_key,
                   self.class::FIELDS.merge(extra))
  end
end
