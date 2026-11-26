class AddColourToCensorRules < ActiveRecord::Migration[8.1]
  def change
    add_column :censor_rules, :colour, :string, null: false, default: 'black'
  end
end
