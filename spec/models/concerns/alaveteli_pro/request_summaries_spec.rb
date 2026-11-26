require 'spec_helper'

RSpec.describe AlaveteliPro::RequestSummaries do
  # Includes the concern without the three methods an including class defines.
  let(:model) do
    Class.new(ApplicationRecord) do
      self.table_name = 'draft_info_requests'
      include AlaveteliPro::RequestSummaries
    end
  end

  %i[
    request_summary_body
    request_summary_public_body_names
    request_summary_categories
  ].each do |name|
    it "tells a class that includes it to implement ##{name}" do
      expect { model.new.public_send(name) }.to raise_error(NotImplementedError)
    end
  end
end
