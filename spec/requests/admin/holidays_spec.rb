require 'spec_helper'

RSpec.describe 'Admin holidays', type: :request do
  before { sign_in FactoryBot.create(:admin_user) }

  describe 'GET index' do
    before do
      FactoryBot.create(:holiday, day: Date.new(2010, 1, 1),
                                  description: 'First holiday')
      FactoryBot.create(:holiday, day: Date.new(2011, 2, 2),
                                  description: 'Second holiday')
      FactoryBot.create(:holiday, day: Date.new(2011, 3, 3),
                                  description: 'Third holiday')
      get admin_holidays_path
    end

    let(:page) { Nokogiri::HTML(response.body) }

    def holidays_in(year)
      page.xpath("//h2[text()='#{year}']/following-sibling::table[1]").
        css('.holiday-description').map(&:text)
    end

    it 'lists the years with holidays, newest first' do
      expect(response).to have_http_status(:ok)
      years = page.css('#existing-holidays h2').map(&:text)
      expect(years & %w[2010 2011]).to eq(%w[2011 2010])
    end

    it 'lists each holiday under its year' do
      expect(holidays_in(2010)).to include('First holiday')
      expect(holidays_in(2010)).not_to include('Second holiday')
      expect(holidays_in(2011)).to include('Second holiday', 'Third holiday')
    end
  end

  describe 'GET new' do
    it 'shows the new holiday page' do
      get new_admin_holiday_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('New public holiday')
      expect(response.body).to include('new-holiday-form')
    end

    it 'answers an ajax request with the form alone' do
      get new_admin_holiday_path, xhr: true
      expect(response.body).to include('new-holiday-form')
      expect(response.body).not_to include('<html')
    end
  end

  describe 'POST create' do
    let(:holiday_params) do
      { :description => "New Year's Day",
        'day(1i)' => '2010',
        'day(2i)' => '1',
        'day(3i)' => '1' }
    end

    it 'creates the holiday' do
      expect { post admin_holidays_path, params: { holiday: holiday_params } }.
        to change(Holiday, :count).by(1)
      holiday = Holiday.last
      expect(holiday.description).to eq("New Year's Day")
      expect(holiday.day).to eq(Date.new(2010, 1, 1))
    end

    it 'redirects to the index with a success message' do
      post admin_holidays_path, params: { holiday: holiday_params }
      expect(response).to redirect_to(admin_holidays_path)
      expect(flash[:notice]).to eq('Holiday successfully created.')
    end

    context 'when there are errors' do
      before do
        allow_any_instance_of(Holiday).to receive(:save).and_return(false)
        post admin_holidays_path, params: { holiday: holiday_params }
      end

      it 'shows the new holiday page again' do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('New public holiday')
      end
    end
  end

  describe 'GET edit' do
    let(:holiday) { FactoryBot.create(:holiday, description: 'Boxing Day') }

    it 'shows the edit page for the holiday' do
      get edit_admin_holiday_path(holiday)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Edit public holiday')
      expect(response.body).to include(admin_holiday_path(holiday))
      expect(response.body).to include('Boxing Day')
    end

    it 'answers an ajax request with the form alone' do
      get edit_admin_holiday_path(holiday), xhr: true
      expect(response.body).to include('edit-holiday-form')
      expect(response.body).to include(admin_holiday_path(holiday))
      expect(response.body).not_to include('<html')
    end
  end

  describe 'PUT update' do
    let(:holiday) do
      FactoryBot.create(:holiday, day: Date.new(2010, 1, 1),
                                  description: 'Test Holiday')
    end

    before do
      put admin_holiday_path(holiday),
          params: { holiday: { description: 'New Test Holiday' } }
    end

    it 'updates the holiday' do
      expect(holiday.reload.description).to eq('New Test Holiday')
    end

    it 'redirects to the index with a success message' do
      expect(response).to redirect_to(admin_holidays_path)
      expect(flash[:notice]).to eq('Holiday successfully updated.')
    end

    context 'when there are errors' do
      before do
        allow_any_instance_of(Holiday).to receive(:update).and_return(false)
        put admin_holiday_path(holiday),
            params: { holiday: { description: 'New Test Holiday' } }
      end

      it 'shows the edit page again' do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('Edit public holiday')
      end
    end
  end

  describe 'DELETE destroy' do
    let!(:holiday) { FactoryBot.create(:holiday) }

    it 'destroys the holiday' do
      expect { delete admin_holiday_path(holiday) }.
        to change(Holiday, :count).by(-1)
      expect(Holiday).not_to exist(holiday.id)
    end

    it 'redirects to the index with a message' do
      delete admin_holiday_path(holiday)
      expect(response).to redirect_to(admin_holidays_path)
      expect(flash[:notice]).to eq('Holiday successfully destroyed')
    end
  end
end
