require 'spec_helper'

%w[
  061_include_responses_in_tracks
  065_add_comments_to_user_track
  20160613145644_add_comments_count_to_users
  20160613151912_add_track_things_count_to_users
  20240209162933_change_citation_type_values
  20241001114832_change_citation_type_values_again
].each { |name| require Rails.root.join('db', 'migrate', name).to_s }

RSpec.describe 'Historical migrations for removed features' do
  let(:connection) { ActiveRecord::Base.connection }

  after do
    %w[track_things citations comments users].each do |table|
      connection.execute("DROP TABLE IF EXISTS pg_temp.#{table}")
    end
    connection.schema_cache.clear!
  end

  it 'updates old track queries and counts without the application model or association' do
    connection.execute <<~SQL
      CREATE TEMPORARY TABLE users (id integer PRIMARY KEY);
      CREATE TEMPORARY TABLE track_things (
        id integer PRIMARY KEY, tracking_user_id integer,
        track_type text, track_query text
      );
      INSERT INTO users VALUES (1), (2), (3);
      INSERT INTO track_things VALUES
        (1, 1, 'user_updates', 'variety:sent requested_by:alice'),
        (2, 1, 'public_body_updates', 'variety:sent requested_from:council'),
        (3, 2, 'search_query', 'variety:sent requested_by:bob'),
        (4, 2, 'user_updates', 'requested_by:bob OR requested_by:carol');
    SQL

    IncludeResponsesInTracks.new.up
    AddCommentsToUserTrack.new.up
    AddTrackThingsCountToUsers.new.up

    expect(connection.
           select_values('SELECT track_query FROM track_things ORDER BY id')).
      to eq(['requested_by:alice OR commented_by:alice',
             'requested_from:council',
             'variety:sent requested_by:bob',
             'requested_by:bob OR requested_by:carol'])
    expect(connection.
           select_values('SELECT track_things_count FROM users ORDER BY id')).
      to eq([2, 2, 0])
  end

  it 'counts old comments without the application model or association' do
    connection.execute <<~SQL
      CREATE TEMPORARY TABLE users (id integer PRIMARY KEY);
      CREATE TEMPORARY TABLE comments (id integer PRIMARY KEY, user_id integer);
      INSERT INTO users VALUES (1), (2), (3);
      INSERT INTO comments VALUES (1, 1), (2, 1), (3, 2), (4, NULL);
    SQL

    AddCommentsCountToUsers.new.up

    expect(connection.
           select_values('SELECT comments_count FROM users ORDER BY id')).
      to eq([2, 1, 0])
  end

  it 'converts citation types in both directions without loading removed STI classes' do
    connection.execute <<~SQL
      CREATE TEMPORARY TABLE citations (id integer PRIMARY KEY, type text);
      INSERT INTO citations VALUES (1, 'news_story'), (2, 'academic_paper'), (3, 'other');
    SQL

    ChangeCitationTypeValues.new.up
    ChangeCitationTypeValuesAgain.new.up
    expect(connection.select_values('SELECT type FROM citations ORDER BY id')).
      to eq(%w[journalism research other])

    ChangeCitationTypeValuesAgain.new.down
    ChangeCitationTypeValues.new.down
    expect(connection.select_values('SELECT type FROM citations ORDER BY id')).
      to eq(%w[news_story academic_paper other])
  end
end
