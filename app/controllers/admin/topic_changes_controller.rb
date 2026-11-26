# The topic content's edit history, newest first: each change's admin (or
# the import, or the command line), record and changed fields.
class Admin::TopicChangesController < AdminController
  ACTION_FILTERS = %w[update create destroy].freeze
  SOURCE_FILTERS = %w[admin system].freeze

  def index
    @topic_pages = TopicPage.order(:title)
    @topic_page = TopicPage.find_by(id: params[:topic].presence)
    @action_kind = params[:action_kind].presence_in(ACTION_FILTERS)
    @source = params[:source].presence_in(SOURCE_FILTERS)

    changes = TopicChange.order(id: :desc).includes(:user, :record)
    changes = changes.for_topic_page(@topic_page) if @topic_page
    changes = changes.where(action: @action_kind) if @action_kind
    changes = changes.where.not(user_id: nil) if @source == 'admin'
    changes = changes.where(user_id: nil) if @source == 'system'

    @topic_changes = changes.paginate(page: params[:page], per_page: 50)
    ActiveRecord::Associations::Preloader.new(
      records: @topic_changes.map(&:record).grep(TopicPage::Row),
      associations: :topic_page
    ).call
  end
end
