# For controller specs of the features PrivateArchive switches off.
#   it_behaves_like 'a feature the private archive switches off',
#                   [[:get, :index], [:post, :create, { id: 1 }]]
RSpec.shared_examples 'a feature the private archive switches off' do |requests|
  requests.each do |verb, action, params|
    it "has no #{verb.upcase} #{action} for a visitor" do
      expect { send(verb, action, params: params || {}) }.
        to raise_error(ActiveRecord::RecordNotFound)
    end

    it "has no #{verb.upcase} #{action} for a signed-in user" do
      sign_in FactoryBot.create(:user)
      expect { send(verb, action, params: params || {}) }.
        to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
