require 'spec_helper'

RSpec.describe 'Admin holiday imports', type: :request do
  before { sign_in FactoryBot.create(:admin_user) }

  let(:page_title) { 'Create holidays from suggestions or iCal feed' }

  def settings_form
    Nokogiri::HTML(response.body).
      at_css("form[action='#{preview_admin_holiday_imports_path}']")
  end

  describe 'GET new' do
    it 'shows the import settings form' do
      get new_admin_holiday_import_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(page_title)
      expect(settings_form).to be_present
    end

    it 'does not populate the import' do
      get new_admin_holiday_import_path,
          params: { holiday_import: { source: 'suggestions' } }
      expect(settings_form).to be_present
      expect(response.body).not_to include('Holidays to import')
    end
  end

  describe 'POST preview' do
    it 'shows the import settings form again' do
      post preview_admin_holiday_imports_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(page_title)
      expect(settings_form).to be_present
    end

    describe 'if the import is valid' do
      it 'populates the import' do
        post preview_admin_holiday_imports_path,
             params: { holiday_import: { source: 'suggestions' } }
        expect(response.body).to include('Holidays to import')
        expect(response.body).to include('Suggested holidays for Germany')
      end
    end

    describe 'if the import is not valid' do
      it 'does not populate the import' do
        post preview_admin_holiday_imports_path,
             params: { holiday_import: { source: 'elsewhere' } }
        expect(response.body).
          to include('There was a problem with these import settings')
        expect(response.body).not_to include('Holidays to import')
      end
    end

    describe 'if the configured country is unknown' do
      it 'says there are no suggestions for the configured code' do
        allow(AlaveteliConfiguration).to receive(:iso_country_code).
          and_return('ZZ')
        post preview_admin_holiday_imports_path,
             params: { holiday_import: { source: 'suggestions' } }
        expect(response.body).
          to include('built-in suggestions for holiday days in ZZ.')
      end
    end
  end

  describe 'POST create' do
    it 'saves an import with no holidays' do
      expect { post admin_holiday_imports_path }.
        not_to change(Holiday, :count)
      expect(response).to redirect_to(admin_holidays_path)
    end

    describe 'when handling an iCal feed' do
      let(:params) do
        {
          'holiday_import' => {
            'holidays_attributes' => {
              '0' => {
                'description' => 'M L King Day',
                'day(1i)' => '2017',
                'day(2i)' => '1',
                'day(3i)' => '16'
              },
              '1' => {
                'description' => 'Thanksgiving Day',
                'day(1i)' => '2017',
                'day(2i)' => '11',
                'day(3i)' => '23'
              }
            }
          },
          'commit' => 'Import'
        }
      end

      before do
        Holiday.delete_all
        post admin_holiday_imports_path, params: params
      end

      it 'creates the expected holidays' do
        expect(Holiday.order(:day).pluck(:description, :day)).
          to eq([['M L King Day', Date.new(2017, 1, 16)],
                 ['Thanksgiving Day', Date.new(2017, 11, 23)]])
      end

      it 'shows a success notice' do
        expect(flash[:notice]).to eq('Holidays successfully imported')
      end

      it 'redirects to the index' do
        expect(response).to redirect_to(admin_holidays_path)
      end
    end

    describe 'if the import cannot be saved' do
      let(:params) do
        { holiday_import: {
          holidays_attributes: { '0' => { description: 'No day' } }
        } }
      end

      it 'shows the import page again without saving' do
        expect { post admin_holiday_imports_path, params: params }.
          not_to change(Holiday, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(page_title)
      end
    end
  end
end
