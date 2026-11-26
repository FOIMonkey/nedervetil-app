# Sign-ins no longer record a country: it came from a GeoIP database that was
# never installed, so every row held the site's own country.
class RemoveCountryFromUserSignIns < ActiveRecord::Migration[8.1]
  def change
    remove_column :user_sign_ins, :country, :string
  end
end
