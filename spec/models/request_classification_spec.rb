# == Schema Information
#
# Table name: request_classifications
#
#  id                    :integer          not null, primary key
#  user_id               :integer
#  info_request_event_id :integer
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#

require 'spec_helper'

RSpec.describe RequestClassification do
  it "counts towards the classifying user's classifications" do
    user = FactoryBot.create(:user)
    FactoryBot.create(:request_classification, user: user)
    expect(user.reload.request_classifications_count).to eq(1)
  end
end
