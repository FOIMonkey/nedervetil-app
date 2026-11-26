require 'spec_helper'
require Rails.root.join(
  'db/migrate/20261118000100_remove_about_me_from_users'
).to_s

# DDL is transactional in PostgreSQL, so each example's schema changes roll
# back with its transaction.
RSpec.describe RemoveAboutMeFromUsers do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { migration.public_send(direction) }
  end

  def about_me_column
    connection.columns(:users).find { _1.name == 'about_me' }
  end

  def set_about_me(user, text)
    connection.execute(<<~SQL)
      UPDATE users SET about_me = #{connection.quote(text)}
      WHERE id = #{user.id}
    SQL
  end

  def about_me_of(user)
    connection.select_value("SELECT about_me FROM users WHERE id = #{user.id}")
  end

  before { migrate(:down) unless about_me_column }

  it 'goes down and up while no account has text' do
    FactoryBot.create(:user)

    migrate(:up)
    expect(about_me_column).to be_nil

    migrate(:down)
    expect(about_me_column).to have_attributes(sql_type: 'text', null: false,
                                               default: '')

    migrate(:up)
    expect(about_me_column).to be_nil
  end

  it 'refuses to drop the column while an account has text, and keeps it' do
    user = FactoryBot.create(:user)
    set_about_me(user, 'I study bus timetables')

    expect { migrate(:up) }.to raise_error(
      RemoveAboutMeFromUsers::AboutMePresent,
      /1 account\(s\) have "About me" text/
    )
    expect(about_me_of(user)).to eq('I study bus timetables')
  end

  it 'counts text that is only whitespace as text' do
    user = FactoryBot.create(:user)
    set_about_me(user, " \n")

    expect { migrate(:up) }.
      to raise_error(RemoveAboutMeFromUsers::AboutMePresent)
    expect(about_me_of(user)).to eq(" \n")
  end
end
