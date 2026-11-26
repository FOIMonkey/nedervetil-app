require 'spec_helper'

RSpec.describe 'Admin categories', type: :request do
  before { sign_in FactoryBot.create(:admin_user) }

  let!(:authority_heading) do
    FactoryBot.create(:category, :public_body, title: 'Authority heading')
  end

  let!(:request_heading) do
    FactoryBot.create(:category, :info_request, title: 'Request heading')
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def field_value(name)
    page.at_css("input[name='#{name}']")&.[]('value')
  end

  def translated_title(locale)
    field_value("category[translations_attributes][#{locale}][title]")
  end

  def heading_choices
    page.css('label.checkbox').map { _1.text.strip }
  end

  def locale_tabs
    page.css('.tab-pane').map { _1['id'].delete_prefix('div-locale-') }
  end

  def newest_category
    Category.order(:id).last
  end

  describe 'GET index' do
    def listed_headings
      page.css('#category_list .accordion-heading strong a').map(&:text)
    end

    it 'lists the headings of public authority categories' do
      get admin_categories_path
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1').text).to start_with('Listing')
      expect(listed_headings).to include('Authority heading')
      expect(listed_headings).not_to include('Request heading')
    end

    it 'raise 404 for unknown types' do
      get admin_categories_path
      expect(response).to have_http_status(:ok)
      expect { get admin_categories_path(model_type: 'unknown') }.
        to raise_error(ApplicationController::RouteNotFound)
    end

    it 'lists the headings for the chosen model' do
      get admin_categories_path(model_type: 'PublicBody')
      expect(listed_headings).to include('Authority heading')
      expect(listed_headings).not_to include('Request heading')

      get admin_categories_path(model_type: 'InfoRequest')
      expect(listed_headings).to include('Request heading')
      expect(listed_headings).not_to include('Authority heading')
    end
  end

  describe 'GET show' do
    it 'redirects to the edit action' do
      category = FactoryBot.create(:category)
      get admin_category_path(category)
      expect(response).to redirect_to(edit_admin_category_path(category))
    end
  end

  describe 'GET new' do
    it 'offers the headings for the chosen model' do
      get new_admin_category_path(model_type: 'PublicBody')
      expect(heading_choices).to include('Authority heading')
      expect(heading_choices).not_to include('Request heading')

      get new_admin_category_path(model_type: 'InfoRequest')
      expect(heading_choices).to include('Request heading')
      expect(heading_choices).not_to include('Authority heading')
    end

    it 'shows an empty form for a new category' do
      get new_admin_category_path
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1').text).to eq('New category')
      form = page.at_css("form[action='#{admin_categories_path(
        model_type: 'PublicBody'
      )}']")
      expect(form).to be_present
      expect(page.at_css("input[name='category[title]']")).to be_present
      expect(field_value('category[title]')).to be_nil
    end

    it 'offers fields for all locales' do
      get new_admin_category_path
      expect(locale_tabs).to eq(AlaveteliLocalization.available_locales)
    end
  end

  describe 'POST create' do
    it 'files the category under the root for the chosen model' do
      post admin_categories_path, params: {
        model_type: 'PublicBody',
        category: { title: 'Title' }
      }
      expect(newest_category.parents).to eq([PublicBody.category_root])

      post admin_categories_path, params: {
        model_type: 'InfoRequest',
        category: { title: 'Title' }
      }
      expect(newest_category.parents).to eq([InfoRequest.category_root])
      expect(response).
        to redirect_to(admin_categories_path(model_type: 'InfoRequest'))
    end

    it "default category's parent associations to root" do
      post admin_categories_path, params: { category: { title: 'Title' } }
      expect(newest_category.parents).
        to match_array(PublicBody.category_root)
    end

    it "saves new category's parent associations" do
      parent = FactoryBot.create(:category)
      post admin_categories_path, params: {
        category: { title: 'Title', parent_ids: [parent.id] }
      }
      expect(newest_category.parents).to match_array(parent)
    end

    context 'on success' do
      let(:params) do
        {
          category_tag: 'new_test_category',
          translations_attributes: {
            'en' => { locale: 'en', title: 'New Category' }
          }
        }
      end

      it 'creates a new category in the default locale' do
        expect {
          post admin_categories_path, params: { category: params }
        }.to change { Category.count }.by(1)
        expect(newest_category.title(:en)).to eq('New Category')
      end

      it 'can create a category when the default locale is an ' \
         'underscore locale' do
        AlaveteliLocalization.set_locales('es en_GB', 'en_GB')
        post admin_categories_path,
             params: { category: { title: 'Category en_GB' } }
        expect(newest_category.translations.first.locale).to eq(:en_GB)
      end

      it 'notifies the admin that the category was created' do
        post admin_categories_path, params: { category: params }
        expect(flash[:notice]).to eq('Category was successfully created.')
      end

      it 'redirects to the categories index' do
        post admin_categories_path, params: { category: params }
        expect(response).
          to redirect_to(admin_categories_path(model_type: 'PublicBody'))
      end
    end

    context 'on success for multiple locales' do
      let(:params) do
        {
          category_tag: 'new_test_category',
          translations_attributes: {
            'en' => { locale: 'en', title: 'New Category' },
            'es' => { locale: 'es', title: 'Mi Nuevo Category' }
          }
        }
      end

      before do
        expect {
          post admin_categories_path, params: { category: params }
        }.to change { Category.count }.by(1)
      end

      it 'saves the default locale translation' do
        expect(newest_category.title(:en)).to eq('New Category')
      end

      it 'saves the alternative locale translation' do
        expect(newest_category.title(:es)).to eq('Mi Nuevo Category')
      end
    end

    context 'on failure' do
      before do
        PublicBody.category_root
        allow_any_instance_of(Category).to receive(:save).and_return(false)
      end

      it 'shows the form again with the given params' do
        expect {
          post admin_categories_path, params: { category: { title: 'Title' } }
        }.not_to(change { Category.count })
        expect(response).to have_http_status(:unprocessable_content)
        expect(page.at_css('h1').text).to eq('New category')
        expect(field_value('category[title]')).to eq('Title')
      end
    end

    context 'on failure for multiple locales' do
      before do
        PublicBody.category_root
        allow_any_instance_of(Category).to receive(:save).and_return(false)
        post admin_categories_path, params: { category: params }
      end

      let(:params) do
        {
          category_tag: 'new_test_category',
          translations_attributes: {
            'en' => { locale: 'en', title: 'My New Category' },
            'es' => { locale: 'es', title: 'Mi Nuevo Category' }
          }
        }
      end

      it 'is rebuilt with the default locale translation' do
        expect(field_value('category[title]')).to eq('My New Category')
      end

      it 'is rebuilt with the alternative locale translation' do
        expect(translated_title(:es)).to eq('Mi Nuevo Category')
      end
    end
  end

  describe 'GET edit' do
    let(:category) do
      FactoryBot.create(
        :category, title_translations: { 'es' => 'Los category' }
      )
    end

    it 'offers the headings for the chosen model' do
      get edit_admin_category_path(category, model_type: 'PublicBody')
      expect(heading_choices).to include('Authority heading')
      expect(heading_choices).not_to include('Request heading')

      get edit_admin_category_path(category, model_type: 'InfoRequest')
      expect(heading_choices).to include('Request heading')
      expect(heading_choices).not_to include('Authority heading')
    end

    it 'shows the requested category' do
      get edit_admin_category_path(category)
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1').text).to eq('Edit category')
      expect(page.at_css("form[action^='#{admin_category_path(category)}']")).
        to be_present
      expect(field_value('category[title]')).to eq('Popular authorities')
      expect(translated_title(:es)).to eq('Los category')
    end

    it 'builds new translations if the body does not already have a ' \
       'translation in the specified locale' do
      get edit_admin_category_path(category)
      expect(locale_tabs).to include('fr')
      expect(page.at_css('#div-locale-fr')).to be_present
    end
  end

  describe 'PUT update' do
    let(:parent) { FactoryBot.create(:category) }

    let(:category) do
      FactoryBot.create(
        :category,
        parents: [parent],
        title_translations: { 'es' => 'Los category' }
      )
    end

    let(:params) do
      {
        category_tag: category.category_tag,
        translations_attributes: {
          'en' => {
            id: category.translation_for(:en).id,
            locale: 'en',
            title: category.title(:en)
          },
          'es' => {
            id: category.translation_for(:es).id,
            locale: 'es',
            title: category.title(:es)
          }
        }
      }
    end

    def stored_category
      Category.find(category.id)
    end

    it 'overrides model type param in favor of the categories root' do
      patch admin_category_path(category), params: {
        model_type: 'PublicBody',
        category: params
      }
      expect(response).
        to redirect_to(admin_categories_path(model_type: 'PublicBody'))

      patch admin_category_path(category), params: {
        model_type: 'InfoRequest',
        category: params
      }
      expect(response).
        to redirect_to(admin_categories_path(model_type: 'PublicBody'))
      expect(stored_category.parents).to eq([PublicBody.category_root])
    end

    it 'updates the chosen category' do
      other = FactoryBot.create(:category, parents: [parent])
      patch admin_category_path(category), params: { category: params }
      expect(stored_category.parents).to eq([PublicBody.category_root])
      expect(Category.find(other.id).parents).to eq([parent])
    end

    it "default category's parent associations to root" do
      patch admin_category_path(category), params: { category: params }
      expect(stored_category.parents).
        to match_array(PublicBody.category_root)
    end

    it "saves edits to a category's parent associations" do
      new_parent = FactoryBot.create(:category)
      patch admin_category_path(category), params: {
        category: { parent_ids: [new_parent.id] }
      }
      expect(stored_category.parents).to match_array(new_parent)
    end

    context 'when the category has associated bodies' do
      before do
        FactoryBot.create(:public_body, tag_string: category.category_tag)
        patch admin_category_path(category), params: {
          category: { category_tag: 'renamed' }
        }
      end

      it 'does not save edits to category' do
        expect(page.css('.error-messages li').map(&:text)).
          to include(a_string_including("can't be changed"))
        expect(stored_category.category_tag).to eq(category.category_tag)
      end

      it 'renders the edit action' do
        expect(response).to have_http_status(:unprocessable_content)
        expect(page.at_css('h1').text).to eq('Edit category')
      end
    end

    context 'on success' do
      let(:params) do
        {
          translations_attributes: {
            'en' => {
              id: category.translation_for(:en).id,
              locale: 'en',
              title: 'Renamed'
            }
          }
        }
      end

      it 'saves edits to a category' do
        patch admin_category_path(category), params: { category: params }
        expect(stored_category.title).to eq('Renamed')
      end

      it 'notifies the admin that the category was created' do
        patch admin_category_path(category), params: { category: params }
        expect(flash[:notice]).to eq('Category was successfully updated.')
      end

      it 'redirects to the category edit page' do
        patch admin_category_path(category), params: { category: params }
        expect(response).
          to redirect_to(admin_categories_path(model_type: 'PublicBody'))
      end

      it 'saves edits to category_tag if the category has no associated ' \
         'bodies' do
        category = FactoryBot.create(:category, category_tag: 'empty')

        patch admin_category_path(category), params: {
          category: { category_tag: 'Renamed' }
        }

        expect(Category.find(category.id).category_tag).to eq('Renamed')
      end

      it "creates a new translation if there isn't one for the " \
         'default_locale' do
        AlaveteliLocalization.set_locales('es en_GB', 'en_GB')

        patch admin_category_path(category), params: {
          category: { title: 'Category en_GB' }
        }

        expect(stored_category.translations.map(&:locale)).
          to include(:en_GB)
      end
    end

    context 'on success for multiple locales' do
      let(:params) do
        {
          category_tag: category.category_tag,
          translations_attributes: {
            'en' => {
              id: category.translation_for(:en).id,
              locale: 'en',
              title: category.title(:en)
            },
            'es' => {
              id: category.translation_for(:es).id,
              locale: 'es',
              title: 'Renamed'
            }
          }
        }
      end

      it 'saves edits to a category in another locale' do
        patch admin_category_path(category), params: { category: params }
        expect(stored_category.title(:es)).to eq('Renamed')
        expect(stored_category.title(:en)).to eq(category.title(:en))
      end

      it 'adds a new translation' do
        put admin_category_path(category), params: {
          category: {
            translations_attributes: {
              'fr' => { locale: 'fr', title: 'Category FR' }
            }
          }
        }

        expect(flash[:notice]).to include('successful')
        expect(stored_category.title(:fr)).to eq('Category FR')
      end

      it 'adds multiple new translations' do
        patch admin_category_path(category), params: {
          category: {
            translations_attributes: {
              'fr' => { locale: 'fr', title: 'Category FR' },
              'cy' => { locale: 'cy', title: 'Category CY' }
            }
          }
        }

        expect(flash[:notice]).to include('successful')
        expect(stored_category.title(:fr)).to eq('Category FR')
        expect(stored_category.title(:cy)).to eq('Category CY')
      end

      it 'updates an existing translation and adds a translation' do
        patch admin_category_path(category), params: {
          category: {
            translations_attributes: {
              'es' => {
                id: category.translation_for(:es).id,
                locale: 'es',
                title: 'Category ES'
              },
              'fr' => { locale: 'fr', title: 'Category FR' }
            }
          }
        }

        expect(flash[:notice]).to include('successful')
        expect(stored_category.title(:es)).to eq('Category ES')
        expect(stored_category.title(:fr)).to eq('Category FR')
      end

      it 'redirects to the edit page after a successful update' do
        patch admin_category_path(category),
              params: { category: { title: 'Title' } }
        expect(response).
          to redirect_to(admin_categories_path(model_type: 'PublicBody'))
      end
    end

    context 'with attachment markup in the body' do
      let(:blob) do
        ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new('uploaded'), filename: 'uploaded.txt'
        )
      end

      let(:html) do
        "<p>Kept</p><action-text-attachment sgid=\"#{blob.attachable_sgid}\">" \
          '</action-text-attachment>'
      end

      before do
        params[:translations_attributes]['en'][:body] = html
        params[:translations_attributes]['es'][:body] = html
        patch admin_category_path(category), params: { category: params }
      end

      it 'stores each locale without the attachment' do
        stored = Category.find(category.id)
        %w[en es].each do |locale|
          body = stored.translation_for(locale).body
          expect(body.body.to_html).to eq('<p>Kept</p>')
          expect(body.embeds).to be_empty
        end
      end
    end

    context 'on failure' do
      before do
        category
        PublicBody.category_root
        allow_any_instance_of(Category).to receive(:save).and_return(false)
        patch admin_category_path(category),
              params: { category: { title: 'Title' } }
      end

      it 'shows the edit form again' do
        expect(response).to have_http_status(:unprocessable_content)
        expect(page.at_css('h1').text).to eq('Edit category')
      end

      it 'is rebuilt with the given params' do
        expect(field_value('category[title]')).to eq('Title')
        expect(stored_category.title).to eq('Popular authorities')
      end
    end

    context 'on failure for multiple locales' do
      before do
        category
        PublicBody.category_root
        allow_any_instance_of(Category).to receive(:save).and_return(false)
        patch admin_category_path(category), params: { category: params }
      end

      let(:params) do
        {
          category_tag: category.category_tag,
          translations_attributes: {
            'en' => {
              id: category.translation_for(:en).id,
              locale: 'en',
              title: 'My Updated Category'
            },
            'es' => {
              id: category.translation_for(:es).id,
              locale: 'es',
              title: 'Mi Categoria Actualizada'
            }
          }
        }
      end

      it 'is rebuilt with the default locale translation' do
        expect(field_value('category[title]')).to eq('My Updated Category')
      end

      it 'is rebuilt with the alternative locale translation' do
        expect(translated_title(:es)).to eq('Mi Categoria Actualizada')
      end
    end
  end

  describe 'DELETE destroy' do
    let!(:category) { FactoryBot.create(:category, category_tag: '123') }

    it 'destroys empty categories' do
      expect {
        delete admin_category_path(category)
      }.to change { Category.count }.by(-1)
      expect(Category).not_to exist(category.id)
    end

    it 'destroys non-empty categories' do
      FactoryBot.create(:public_body, tag_string: '123')
      expect {
        delete admin_category_path(category)
      }.to change { Category.count }.by(-1)
      expect(Category).not_to exist(category.id)
    end

    it 'notifies the admin that the category was destroyed' do
      delete admin_category_path(category)
      expect(flash[:notice]).to eq('Category was successfully destroyed.')
    end

    it 'redirects to the categories index' do
      delete admin_category_path(category)
      expect(response).
        to redirect_to(admin_categories_path(model_type: 'PublicBody'))
    end
  end

  describe 'POST reorder' do
    let(:parent) { FactoryBot.create(:category) }
    let!(:category_1) { FactoryBot.create(:category, parents: [parent]) }
    let!(:category_2) { FactoryBot.create(:category, parents: [parent]) }

    it 'responds successfully' do
      post reorder_admin_category_path(parent),
           params: { categories: [category_2.id, category_1.id] }
      expect(response).to be_successful
    end

    it 'reorders existing child categories' do
      expect {
        post reorder_admin_category_path(parent),
             params: { categories: [category_2.id, category_1.id] }
      }.to(
        change { parent.children.ids }.
        from([category_1.id, category_2.id]).
        to([category_2.id, category_1.id])
      )
    end

    it 'returns error if trying to reorder non-child categories' do
      other_category = FactoryBot.create(:category)
      post reorder_admin_category_path(parent),
           params: { categories: [category_1.id, other_category.id] }
      expect(response).to_not be_successful
      expect(response.body).
        to eq("Couldn't find Category #{other_category.id}")
    end

    it 'sends the error as plain text, so a sent id is never markup' do
      post reorder_admin_category_path(parent),
           params: { categories: [category_1.id, '<b>x</b>'] }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq('text/plain')
      expect(response.body).to eq("Couldn't find Category <b>x</b>")
    end
  end
end
