require 'spec_helper'

RSpec.describe 'Admin snippets', type: :request do
  before { sign_in FactoryBot.create(:admin_user) }

  let(:page) { Nokogiri::HTML(response.body) }

  def shows_title(title)
    expect(page.at_css('title').text).to include(title)
    expect(page.at_css('h1').text).to eq(title)
  end

  def snippet_form(path)
    page.at_css(%(#admin_snippet_form form[action="#{path}"]))
  end

  describe 'GET index' do
    let!(:snippets) do
      FactoryBot.create_list(:outgoing_message_snippet, 3)
    end

    before { get admin_snippets_path }

    it 'shows the snippets page' do
      expect(response).to have_http_status(:ok)
      shows_title('Listing Snippets')
    end

    it 'lists the snippets' do
      listed = page.css('#snippets .item-title a[href$="/edit"]').
        map { |link| link['href'] }
      expect(listed).to match_array(
        snippets.map { |snippet| edit_admin_snippet_path(snippet) }
      )
    end
  end

  describe 'GET new' do
    before { get new_admin_snippet_path }

    it 'shows the new snippet form' do
      expect(response).to have_http_status(:ok)
      shows_title('New snippet')
      expect(snippet_form(admin_snippets_path)).to be_present
    end
  end

  describe 'POST create' do
    context 'on a successful create' do
      let(:params) do
        { outgoing_message_snippet: { name: 'New name', body: 'New body' } }
      end

      it 'creates the snippet' do
        expect { post admin_snippets_path, params: params }.
          to change(OutgoingMessage::Snippet, :count).by(1)
        snippet = OutgoingMessage::Snippet.last
        expect(snippet.name).to eq('New name')
        expect(snippet.body).to eq('New body')
      end

      it 'sets a notice' do
        post admin_snippets_path, params: params
        expect(flash[:notice]).to eq('Snippet successfully created.')
      end

      it 'redirects to the snippets index' do
        post admin_snippets_path, params: params
        expect(response).to redirect_to(admin_snippets_path)
      end
    end

    context 'on an unsuccessful create' do
      let(:params) do
        { outgoing_message_snippet: { body: '' } }
      end

      it 'does not create the snippet' do
        expect { post admin_snippets_path, params: params }.
          not_to change(OutgoingMessage::Snippet, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'shows the new snippet form again' do
        post admin_snippets_path, params: params
        expect(response).to have_http_status(:unprocessable_content)
        shows_title('New snippet')
        expect(snippet_form(admin_snippets_path)).to be_present
      end
    end
  end

  describe 'GET edit' do
    let!(:snippet) do
      FactoryBot.create(:outgoing_message_snippet, name: 'Edited snippet')
    end

    before { get edit_admin_snippet_path(snippet) }

    it 'shows the edit form for the snippet' do
      expect(response).to have_http_status(:ok)
      shows_title('Edit snippet')
      form = snippet_form(admin_snippet_path(snippet))
      expect(form).to be_present
      expect(form.css('input[type=text]').map { |i| i['value'] }).
        to include('Edited snippet')
    end
  end

  describe 'PATCH update' do
    let!(:snippet) { FactoryBot.create(:outgoing_message_snippet) }

    before do
      patch admin_snippet_path(snippet), params: params
    end

    context 'on a successful update' do
      let(:params) do
        { outgoing_message_snippet: { body: 'New body' } }
      end

      it 'updates the snippet' do
        expect(snippet.reload.body).to eq('New body')
      end

      it 'sets a notice' do
        expect(flash[:notice]).to eq('Snippet successfully updated.')
      end

      it 'redirects to the snippets index' do
        expect(response).to redirect_to(admin_snippets_path)
      end
    end

    context 'on an unsuccessful update' do
      let(:params) do
        { outgoing_message_snippet: { body: '' } }
      end

      it 'does not update the snippet' do
        expect(snippet.reload.body).not_to be_blank
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'shows the edit form for the snippet again' do
        expect(response).to have_http_status(:unprocessable_content)
        shows_title('Edit snippet')
        expect(snippet_form(admin_snippet_path(snippet))).to be_present
      end
    end
  end

  describe 'DELETE destroy' do
    let!(:snippet) { FactoryBot.create(:outgoing_message_snippet) }

    it 'destroys the snippet' do
      expect { delete admin_snippet_path(snippet) }.
        to change(OutgoingMessage::Snippet, :count).by(-1)
      expect(OutgoingMessage::Snippet).not_to exist(snippet.id)
    end

    it 'sets a notice' do
      delete admin_snippet_path(snippet)
      expect(flash[:notice]).to eq('Snippet successfully destroyed.')
    end

    it 'redirects to the snippets index' do
      delete admin_snippet_path(snippet)
      expect(response).to redirect_to(admin_snippets_path)
    end
  end
end
