require 'spec_helper'

RSpec.describe 'reports/new' do
  let(:info_request) { FactoryBot.create(:info_request) }
  before :each do
    assign(:info_request, info_request)
    assign(:report_reasons, info_request.report_reasons)
  end

  it "should show a form" do
    render
    expect(rendered).to have_css("form")
  end

  context "reporting a request" do
    it "has a 'Report request' button" do
      render
      expect(rendered).to have_button("Report request")
    end
  end

  context "request has already been reported" do
    before :each do
      allow(info_request).to receive(:attention_requested).and_return(true)
    end

    it "should not show a form" do
      render
      expect(rendered).to have_no_css("form")
    end

    it "should say it's already been reported" do
      render
      expect(rendered).to have_content("This request has already been reported")
    end
  end
end
