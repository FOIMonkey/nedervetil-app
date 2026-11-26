# When the job a masking rule's save queues (Disclosures::RuleJob) finished
# applying it to the published documents and the thread files it reaches.
# Empty while that work is still to do: each save of the rule empties it.
# A rule saved before the column existed was applied as it was saved, so it
# starts as finished then.
class AddMaskingFinishedAtToCensorRules < ActiveRecord::Migration[8.1]
  def up
    add_column :censor_rules, :masking_finished_at, :datetime
    execute 'UPDATE censor_rules SET masking_finished_at = updated_at'
  end

  def down
    remove_column :censor_rules, :masking_finished_at
  end
end
