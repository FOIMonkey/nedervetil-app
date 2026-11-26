class IncludeResponsesInTracks < ActiveRecord::Migration[4.2] # 2.0
  # The application model was removed; fresh installs still replay this data change.
  class TrackThing < ActiveRecord::Base
    self.table_name = 'track_things'
  end

  def self.up
    TrackThing.update_all "track_query = replace(track_query, 'variety:sent ', '') where track_type in ('public_body_updates', 'user_updates')"
  end

  def self.down
    # TODO: forget it
  end
end
