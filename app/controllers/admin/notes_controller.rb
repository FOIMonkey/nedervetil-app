# Manages translated editorial Note records attached to a notable record or tag
# in the admin interface.
class Admin::NotesController < AdminController
  include Admin::TagHelper
  include TranslatableParams

  def index
    @notes = Note.order(id: :desc).paginate(page: params[:page], per_page: 50)
  end

  def new
    @note = scope.build
    applies_to_something!(@note)
    @note.build_all_translations
  end

  def create
    @note = scope.build(note_params)
    applies_to_something!(@note)
    if @note.save
      notice = 'Note successfully created.'
      redirect_to admin_note_parent_path(@note), notice: notice
    else
      @note.build_all_translations
      render :new, status: :unprocessable_content
    end
  end

  def edit
    @note = scope.find(params[:id])
    @note.build_all_translations
  end

  def update
    @note = scope.find(params[:id])
    if @note.update(note_params)
      notice = 'Note successfully updated.'
      redirect_to admin_note_parent_path(@note), notice: notice
    else
      @note.build_all_translations
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @note = Note.find(params[:id])
    @note.destroy
    notice = 'Note successfully destroyed.'
    redirect_to admin_note_parent_path(@note), notice: notice
  end

  private

  # Require either a notable record or a tag; orphan note forms have no target.
  def applies_to_something!(note)
    return if note.notable || note.notable_tag.present?

    raise ActiveRecord::RecordNotFound
  end

  def scope
    filters = params.slice(:notable_tag, :notable_id, :notable_type).
              permit(:notable_tag, :notable_id, :notable_type)
    Note.where(filters)
  end

  def note_params
    translatable_params(
      params.require(:note),
      translated_keys: [:locale, :body, :rich_body],
      general_keys: [:notable_tag, :notable_id, :notable_type, :style]
    )
  end
end
