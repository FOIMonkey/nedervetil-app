require 'spec_helper'

RSpec.describe 'Wording' do
  describe 'status names' do
    {
      'successful' => 'All information provided',
      'partially_successful' => 'Some information provided',
      'rejected' => 'No information',
      'not_held' => 'No information',
      'waiting_response' => 'Waiting response',
      'waiting_response_overdue' => 'Waiting response, overdue',
      'waiting_response_very_overdue' => 'Waiting response, long overdue',
      'waiting_classification' => 'Waiting classification',
      'internal_review' => 'Internal review'
    }.each do |state, name|
      it "calls #{state} \"#{name}\"" do
        expect(InfoRequest.get_status_description(state)).to eq(name)
      end
    end

    it 'uses the same names in lists' do
      expect(InfoRequest::State.short_description('successful')).
        to eq('All information provided')
      expect(InfoRequest::State.short_description('waiting_classification')).
        to eq('Waiting classification')
    end
  end
end
