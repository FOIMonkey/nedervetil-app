# Previews and saves bulk Holiday records imported via HolidayImport from
# country suggestions or an iCal feed.
class Admin::HolidayImportsController < AdminController
  # A flat JSON body keeps the key it had before this controller moved here.
  wrap_parameters :admin_holiday_import, exclude: []

  def new
    @holiday_import = HolidayImport.new
  end

  def preview
    @holiday_import = HolidayImport.new(holiday_import_params)
    @holiday_import.populate if @holiday_import.valid?
    render :new
  end

  def create
    @holiday_import = HolidayImport.new(holiday_import_params)
    if @holiday_import.save
      notice = "Holidays successfully imported"
      redirect_to admin_holidays_path, notice: notice
    else
      render :new, status: :unprocessable_content
    end
  end

  private

  def holiday_import_params
    if params[:holiday_import]
      params.
        require(:holiday_import).
          permit(:start_year,
                 :end_year,
                 :source,
                 :ical_feed_url,
                 holidays_attributes: [:description, :day])
    else
      {}
    end
  end
end
