# Lists, adds and removes blocklisted SpamAddress entries in the admin
# interface.
class Admin::SpamAddressesController < AdminController
  # A flat JSON body keeps the key it had before this controller moved here.
  wrap_parameters :admin_spam_address, exclude: []

  before_action :set_spam_address, only: [:destroy]

  def index
    @spam_addresses = SpamAddress.all
    @spam_address = SpamAddress.new
  end

  def create
    @spam_address = SpamAddress.new(spam_address_params)
    if @spam_address.save
      notice =
        "#{ @spam_address.email } has been added to the spam addresses list"
      redirect_to admin_spam_addresses_path, notice: notice
    else
      @spam_addresses = SpamAddress.all
      render :index, status: :unprocessable_content
    end
  end

  def destroy
    @spam_address.destroy
    notice =
      "#{ @spam_address.email } has been removed from the spam addresses list"
    redirect_to admin_spam_addresses_path, notice: notice
  end

  private

  def spam_address_params
    if params[:spam_address]
      params.require(:spam_address).permit(:email)
    else
      {}
    end
  end

  def set_spam_address
    @spam_address = SpamAddress.find(params[:id])
  end
end
