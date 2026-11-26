require 'spec_helper'

RSpec.describe 'Admin authority page links', type: :request do
  let(:admin) { FactoryBot.create(:admin_user) }

  let(:link) do
    AuthorityFeeds::Link.create!(label: 'Spending',
                                 url_template: 'https://example.test/{url_name}',
                                 position: 30)
  end

  let(:page) { Nokogiri::HTML(response.body) }

  def field_value(name)
    page.at_css("input[name='#{name}']")&.[]('value')
  end

  context 'as an admin' do
    before { sign_in admin }

    it 'offers the next position for a new link' do
      link
      get new_admin_authority_link_path
      expect(response).to have_http_status(:ok)
      expect(page.at_css("form[action='#{admin_authority_links_path}']")).
        to be_present
      expect(page.at_css("input[name='link[label]']")).to be_present
      expect(field_value('link[label]')).to be_nil
      expect(field_value('link[position]')).to eq('40')
    end

    it 'edits the chosen link' do
      get edit_admin_authority_link_path(link)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Edit Spending')
      expect(page.at_css("form[action='#{admin_authority_link_path(link)}']")).
        to be_present
      expect(field_value('link[label]')).to eq('Spending')
    end

    it 'creates a valid link and returns to authority pages' do
      expect do
        post admin_authority_links_path,
             params: { link: { label: 'Decisions',
                               url_template: '/decisions/{url_name}',
                               tag: 'decisions:', position: 20 } }
      end.to change(AuthorityFeeds::Link, :count).by(1)
      expect(response).to redirect_to(admin_authority_pages_path)
      expect(AuthorityFeeds::Link.last.attributes).
        to include('label' => 'Decisions', 'tag' => 'decisions',
                   'position' => 20)
    end

    it 'renders an invalid creation without adding a link' do
      expect do
        post admin_authority_links_path, params: {
          link: { label: '', url_template: 'javascript:x' }
        }
      end.not_to change(AuthorityFeeds::Link, :count)
      expect(response).to have_http_status(422)
      expect(response.body).to include('Add link')
      expect(page.at_css("form[action='#{admin_authority_links_path}']")).
        to be_present
      expect(page.css('.alert-error li')).to be_present
    end

    it 'saves valid edits to the chosen link' do
      patch admin_authority_link_path(link),
            params: { link: { label: 'New title' } }
      expect(response).to redirect_to(admin_authority_pages_path)
      expect(link.reload.label).to eq('New title')
    end

    it 'renders invalid edits without changing the stored link' do
      patch admin_authority_link_path(link),
            params: { link: { url_template: '{value}' } }
      expect(response).to have_http_status(422)
      expect(response.body).to include('Edit Spending')
      expect(page.css('.alert-error li').map(&:text)).
        to include(a_string_starting_with('Url template'))
      expect(link.reload.url_template).
        to eq('https://example.test/{url_name}')
    end

    it 'deletes the chosen link' do
      link
      expect { delete admin_authority_link_path(link) }.
        to change(AuthorityFeeds::Link, :count).by(-1)
      expect(response).to redirect_to(admin_authority_pages_path)
    end
  end

  context 'when signed out' do
    it 'asks the visitor to sign in' do
      get edit_admin_authority_link_path(link)
      expect(response).to be_redirect
      expect(response.location).to include('sign_in')
    end
  end

  context 'as an ordinary user' do
    let(:params) do
      { link: { label: 'Unapproved edit', url_template: '/changed' } }
    end

    let(:requests) do
      { new: [:get, new_admin_authority_link_path],
        edit: [:get, edit_admin_authority_link_path(link)],
        create: [:post, admin_authority_links_path],
        update: [:patch, admin_authority_link_path(link)],
        destroy: [:delete, admin_authority_link_path(link)] }
    end

    before { sign_in FactoryBot.create(:user) }

    %i[new edit create update destroy].each do |action|
      it "denies #{action} without changing links" do
        before = link.attributes
        verb, path = requests.fetch(action)
        expect { send(verb, path, params: params) }.
          not_to change(AuthorityFeeds::Link, :count)
        # A signed-out visitor is sent to sign in; a signed-in one is not
        # told the page exists.
        expect(response).to have_http_status(:not_found)
        expect(link.reload.attributes).to eq(before)
      end
    end
  end
end
