require 'ostruct'

##
# A superclass for question, actions and suggestions that are presented to users
# to help them challenge refusals.
#
class RefusalAdvice::Block
  def initialize(data)
    @data = data
  end

  def id
    data[:id]
  end

  def show_if
    data[:show_if]
  end

  def ==(other)
    data == other.data
  end

  protected

  attr_reader :data

  private

  def collection(value)
    Array(value).map { |item| object(item) }
  end

  def object(value)
    OpenStruct.new(value) if value
  end

  def renderable_object(value)
    return { plain: '' } unless value

    params = ActionController::Parameters.new(value).permit(
      :partial, :plain, :html
    )
    # rubocop:disable Rails/OutputSafety -- HTML written in the site's own config/refusal_advice files
    params[:html] = params[:html].html_safe if params[:html]
    # rubocop:enable Rails/OutputSafety
    params.to_h
  end
end
