require 'spec_helper'

RSpec.describe PublicBodyCategory::CategoryCollection do
  context "requesting data" do
    before do
      data = ["Local and regional",
              ["local_council", "Local councils", "a local council"],
              "Miscellaneous",
              %w[other Miscellaneous miscellaneous]]
      @categories = PublicBodyCategory::CategoryCollection.new
      data.each { |item| @categories << item }
    end

    describe 'when asked for headings' do
      it 'should return a list of headings' do
        expect(@categories.headings).
          to eq(['Local and regional', 'Miscellaneous'])
      end
    end

    describe 'when asked for categories with description' do
      # rubocop:disable Layout/LineLength -- a description that spans lines
      it 'should return a list of tag specifications as lists in the form:
                ["tag_to_use_as_category", "Sub category title", "Instance description"]' do
        # rubocop:enable Layout/LineLength
        expected_categories = [
          ["local_council", "Local councils", "a local council"],
          ["other", "Miscellaneous", "miscellaneous"]
        ]
        expect(@categories.with_description).to eq(expected_categories)
      end
    end

    describe 'when asked for tags' do
      it 'should return a list of tags' do
        expect(@categories.tags).to eq(%w[local_council other])
      end
    end

    describe 'when asked for categories by tag' do
      it 'should return a hash of categories keyed by tag' do
        expect(@categories.by_tag).to eq({
                                           "local_council" => "Local councils",
                                           "other" => "Miscellaneous"
                                         })
      end
    end
  end
end
