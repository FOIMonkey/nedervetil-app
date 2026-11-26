require 'spec_helper'

RSpec.describe "admin/users/_user_table" do
  let(:admin_user) { FactoryBot.create(:admin_user) }
  let(:users) do
    FactoryBot.create(:user, name: "Samuel Beckett")
    FactoryBot.create(:user, name: "Fintan O'Toole")
    User.where(name: ["Samuel Beckett", "Fintan O'Toole"]).
      paginate(page: 1, per_page: 100)
  end

  it 'does not double escape apostrophes' do
    allow(controller).to receive(:current_user).and_return(admin_user)
    render partial: 'admin/users/user_table',
           locals: { users: users }
    expect(rendered).to match("O&#39;Toole")
  end
end
