# Lists, creates, edits and deletes public Holiday records grouped by year in
# the admin interface.
class Admin::HolidaysController < AdminController
  # A flat JSON body keeps the key it had before this controller moved here.
  wrap_parameters :admin_holiday, exclude: []

  before_action :set_holiday, only: [:edit, :update, :destroy]

  def index
    load_holidays
  end

  def new
    @holiday = Holiday.new
    if request.xhr?
      render partial: 'new_form', locals: { holiday: @holiday }
    else
      render action: 'new'
    end
  end

  def create
    @holiday = Holiday.new(holiday_params)
    if @holiday.save
      notice = "Holiday successfully created."
      redirect_to admin_holidays_path, notice: notice
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
    if request.xhr?
      render partial: 'edit_form'
    else
      render action: 'edit'
    end
  end

  def update
    if @holiday.update(holiday_params)
      flash[:notice] = 'Holiday successfully updated.'
      redirect_to admin_holidays_path
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @holiday.destroy
    notice = "Holiday successfully destroyed"
    redirect_to admin_holidays_path, notice: notice
  end

  private

  def load_holidays
    @holidays_by_year = Holiday.all.group_by { |holiday| holiday.day.year }
    @years = @holidays_by_year.keys.sort.reverse
  end

  def holiday_params
    if params[:holiday]
      params.require(:holiday).
        permit(:description, 'day(1i)', 'day(2i)', 'day(3i)')
    else
      {}
    end
  end

  def set_holiday
    @holiday = Holiday.find(params[:id])
  end
end
