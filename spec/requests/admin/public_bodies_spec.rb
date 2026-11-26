require 'spec_helper'

RSpec.describe 'Admin public bodies', type: :request do
  def page
    Nokogiri::HTML(response.body)
  end

  def field_value(name)
    page.at_css("input[name='#{name}']")&.[]('value')
  end

  def field_text(name)
    page.at_css("textarea[name='#{name}']")&.text
  end

  def translation_field(locale, attribute)
    "public_body[translations_attributes][#{locale}][#{attribute}]"
  end

  def listed_ids
    page.css('#bodies .item-detail').map { _1['id'].delete_prefix('body_') }.
      map(&:to_i)
  end

  def signed_in_as
    page.at_css('.admin-bar__who')&.text
  end

  context 'as an admin' do
    let(:admin_user) { FactoryBot.create(:admin_user) }

    before { sign_in admin_user }

    describe 'POST import_csv with a temporary file name' do
      it 'rejects a CSV upload name with path or newline characters' do
        expect {
          post import_csv_admin_bodies_path,
               params: { temporary_csv_file: "csv_upload-20261115-1\n" \
                                             '/../../private',
                         original_csv_file: 'original_contents.txt',
                         commit: 'Dry run' }
        }.to raise_error(/Invalid filename/)
      end
    end

    describe 'GET index' do
      it 'returns successfully' do
        get admin_bodies_path
        expect(response).to be_successful
        expect(page.at_css('h1').text).to eq('Listing public authorities')
      end

      it "searches for 'humpa' with the legacy search" do
        get admin_bodies_path(query: 'humpa', search_engine: 'legacy')
        expect(listed_ids).to eq([public_bodies(:humpadink_public_body).id])
      end

      it "searches for 'humpa' in another locale  with the legacy search" do
        cookies[:locale] = 'es'
        get admin_bodies_path(query: 'humpa', search_engine: 'legacy')
        expect(listed_ids).to eq([public_bodies(:humpadink_public_body).id])
      end

      it 'eager loads associations for the legacy search' do
        queries = []
        record = ->(*, payload) { queries << payload[:sql] }
        count = -> do
          queries.clear
          ActiveSupport::Notifications.
            subscribed(record, 'sql.active_record') do
              get admin_bodies_path(query: 'humpa', search_engine: 'legacy')
            end
          [queries.grep(/FROM "has_tag_string_tags"/).size,
           queries.grep(/public_body_translations/).size]
        end

        # The first request also reads the table definitions.
        count.call
        one = count.call
        expect(one).to all(be_positive)
        expect(listed_ids.size).to eq(1)
        3.times do |n|
          FactoryBot.create(:public_body, name: "Humpa extra #{n}",
                                          tag_string: "extra#{n}")
        end
        four = count.call
        expect(listed_ids.size).to eq(4)
        expect(four).to eq(one)
      end

      it 'lists all authorities in name order' do
        get admin_bodies_path
        names = listed_ids.map { PublicBody.find(_1).name }
        expect(names).not_to be_empty
        expect(names).to eq(names.sort_by(&:downcase))
      end

      it "lists an authority's tags in the order they were added" do
        body = FactoryBot.create(:public_body,
                                 tag_string: 'first second third')
        # A row that is changed moves in the table.
        body.tags.first.update!(value: 'changed')

        get admin_bodies_path
        row = page.at_css("#body_#{body.id}").parent
        tags = row.css('.item-metadata .tag').map { _1.text.strip }
        expect(tags.map { _1.split(':').first }).
          to eq(%w[first second third])
      end

      it 'lists the best match first with the new search', :postgresql do
        FactoryBot.create(:public_body, name: 'Otter Watch')
        strong = FactoryBot.create(:public_body,
                                   name: 'Otter Otter Otter Watch')
        get admin_bodies_path(query: 'otter', search_engine: 'new')
        expect(listed_ids.first).to eq(strong.id)
      end

      it 'searches for a request email with the new search', :postgresql do
        get admin_bodies_path(query: 'humpadink-requests@localhost',
                              search_engine: 'new')
        expect(listed_ids).to eq([public_bodies(:humpadink_public_body).id])
      end
    end

    describe 'GET show' do
      let(:public_body) { FactoryBot.create(:public_body) }
      let(:info_request) do
        FactoryBot.create(:info_request, public_body: public_body)
      end

      it 'returns successfully' do
        get admin_body_path(public_body)
        expect(response).to be_successful
        expect(page.at_css('.admin-summary h1').text).to eq(public_body.name)
      end

      it 'uses the authenticated account' do
        get admin_body_path(public_body)
        expect(signed_in_as).to eq(admin_user.name)
      end

      context 'with a home page stored before it was checked' do
        it 'shows it as text, not as a link' do
          public_body.update_column(:home_page,
                                    'javascript:alert(1)//http://example.org')
          get admin_body_path(public_body)
          expect(response.body).to include('javascript:alert(1)')
          expect(page.css('a[href^="javascript"]')).to be_empty
        end
      end

      it 'shows a public body in another locale' do
        AlaveteliLocalization.with_locale('es') do
          public_body.name = 'El Public Body'
          public_body.save!
        end
        cookies[:locale] = 'es'
        get admin_body_path(public_body)
        expect(page.at_css('.admin-summary h1').text).to eq('El Public Body')
      end

      it 'includes all the requests to the body' do
        info_request
        get admin_body_path(public_body)
        expect(response.body).to include(admin_request_path(info_request))
      end
    end

    describe 'GET new' do
      it 'shows a form for a new public body' do
        get new_admin_body_path
        expect(response).to be_successful
        expect(page.at_css('h1').text).to eq('New public authority')
        form = page.at_css('#public_body_form form')
        expect(form['action']).to eq(admin_bodies_path)
        expect(field_value('public_body[name]').to_s).to eq('')
      end

      it 'builds new translations for all locales' do
        get new_admin_body_path
        locales = page.css('#div-locales .tab-pane').
          map { _1['id'].delete_prefix('div-locale-') }
        expect(locales).
          to match_array(AlaveteliLocalization.available_locales)
      end

      context 'when passed a change request id as a param' do
        let(:change_request) { FactoryBot.create(:add_body_request) }

        before do
          get new_admin_body_path(change_request_id: change_request.id)
        end

        it 'should populate the name, email address and last edit comment ' \
           'on the public body' do
          expect(field_value('public_body[name]')).
            to eq(change_request.public_body_name)
          expect(field_value('public_body[request_email]')).
            to eq(change_request.public_body_email)
          expect(field_text('public_body[last_edit_comment]')).
            to match('Notes: Please')
        end

        it 'should show a default response text' do
          expect(page.at_css('#change_request_user_response_field').text).
            to match('Thanks for your suggestion to add A New Body')
        end
      end
    end

    describe 'POST create' do
      context 'on success' do
        let(:params) do
          { public_body: { name: 'New Quango',
                           short_name: 'nq',
                           request_email: 'newquango@localhost',
                           tag_string: 'spec',
                           last_edit_comment: 'From test code' } }
        end

        it 'creates a new body in the default locale' do
          # FIXME: Can't call PublicBody.destroy_all because database
          # database constraints prevent them being deleted.
          existing = PublicBody.count
          expected = existing + 1
          expect {
            post admin_bodies_path, params: params
          }.to change { PublicBody.count }.from(existing).to(expected)
        end

        it 'can create a public body when the default locale is an ' \
           'underscore locale' do
          AlaveteliLocalization.set_locales('es en_GB', 'en_GB')
          post admin_bodies_path, params: params
          expect(
            PublicBody.find_by_name('New Quango').translations.first.locale
          ).to eq(:en_GB)
        end

        it 'notifies the admin that the body was created' do
          post admin_bodies_path, params: params
          expect(flash[:notice]).to eq('PublicBody was successfully created.')
        end

        it 'redirects to the admin page of the body' do
          post admin_bodies_path, params: params
          body = PublicBody.find_by_name('New Quango')
          expect(response).to redirect_to(admin_body_path(body))
        end
      end

      context 'on success for multiple locales' do
        let(:params) do
          { public_body: { name: 'New Quango',
                           short_name: 'nq',
                           request_email: 'newquango@localhost',
                           tag_string: 'spec',
                           last_edit_comment: 'From test code',
                           translations_attributes: {
                             'es' => { locale: 'es',
                                       name: 'Los Quango',
                                       short_name: 'lq' }
                           } } }
        end

        it 'saves the body' do
          # FIXME: Can't call PublicBody.destroy_all because database
          # database constraints prevent them being deleted.
          existing = PublicBody.count
          expected = existing + 1
          expect {
            post admin_bodies_path, params: params
          }.to change { PublicBody.count }.from(existing).to(expected)
        end

        it 'saves the default locale translation' do
          post admin_bodies_path, params: params

          body = PublicBody.find_by_name('New Quango')

          AlaveteliLocalization.with_locale(:en) do
            expect(body.name).to eq('New Quango')
          end
        end

        it 'saves the alternative locale translation' do
          post admin_bodies_path, params: params

          body = PublicBody.find_by_name('New Quango')

          AlaveteliLocalization.with_locale(:es) do
            expect(body.name).to eq('Los Quango')
            expect(body.url_name).to eq('lq')
            expect(body.first_letter).to eq('L')
          end
        end
      end

      context 'on failure' do
        it 'shows the form again if creating the record was unsuccessful' do
          expect {
            post admin_bodies_path, params: {
              public_body: { name: '', translations_attributes: {} }
            }
          }.not_to change(PublicBody, :count)
          expect(response).to have_http_status(:unprocessable_content)
          expect(page.at_css('h1').text).to eq('New public authority')
        end

        it 'is rebuilt with the given params' do
          post admin_bodies_path, params: {
            public_body: {
              name: '',
              request_email: 'newquango@localhost',
              translations_attributes: {}
            }
          }
          expect(field_value('public_body[request_email]')).
            to eq('newquango@localhost')
        end
      end

      context 'on failure for multiple locales' do
        let(:params) do
          { public_body: { name: '',
                           request_email: 'newquango@localhost',
                           translations_attributes: {
                             'es' => { locale: 'es',
                                       name: 'Los Quango' }
                           } } }
        end

        it 'is rebuilt with the default locale translation' do
          expect { post admin_bodies_path, params: params }.
            not_to change(PublicBody, :count)
          expect(page.at_css('h1').text).to eq('New public authority')
          expect(field_value('public_body[request_email]')).
            to eq('newquango@localhost')
        end

        it 'is rebuilt with the alternative locale translation' do
          expect { post admin_bodies_path, params: params }.
            not_to change(PublicBody, :count)
          expect(field_value(translation_field(:es, :name))).
            to eq('Los Quango')
        end
      end

      context 'when the body is being created as a result of a change ' \
              'request' do
        let!(:change_request) { FactoryBot.create(:add_body_request) }

        before do
          post admin_bodies_path,
               params: {
                 public_body: {
                   name: 'New Quango',
                   short_name: '',
                   tag_string: 'blah',
                   request_email: 'newquango@localhost',
                   last_edit_comment: 'From test code'
                 },
                 change_request_id: change_request.id,
                 subject: 'Adding a new body',
                 response: 'The URL will be ' \
                           '[Authority URL will be inserted here]'
               }
        end

        it 'should send a response to the requesting user' do
          deliveries = ActionMailer::Base.deliveries
          expect(deliveries.size).to eq(1)
          mail = deliveries[0]
          expect(mail.subject).to eq('Adding a new body')
          expect(mail.to).to eq([change_request.requester_email])
          expect(mail.body).
            to match(%r{The URL will be http://www.example.com/body/new_quango})
        end

        it 'should mark the change request as closed' do
          expect(PublicBodyChangeRequest.find(change_request.id).is_open).
            to be false
        end
      end
    end

    describe 'GET edit' do
      let(:body) do
        body = FactoryBot.create(:public_body)
        AlaveteliLocalization.with_locale('es') do
          body.name = 'Los Body'
          body.save!
        end
        body
      end

      it 'shows the edit form for the requested body' do
        get edit_admin_body_path(body)
        expect(response).to be_successful
        expect(page.at_css('h1').text).to eq('Edit public body')
        form = page.at_css('#public_body_form form')
        expect(form['action']).to eq(admin_body_path(body))
        expect(field_value('public_body[name]')).to eq(body.name(:en))
        expect(field_value(translation_field(:es, :name))).to eq('Los Body')
      end

      it 'builds new translations if the body does not already have a ' \
         'translation in the specified locale' do
        get edit_admin_body_path(body)
        expect(page.at_css('#div-locale-fr')).to be_present
        expect(field_value(translation_field(:fr, :locale))).to eq('fr')
      end

      it 'edits a public body in another locale' do
        cookies[:locale] = 'en'
        get edit_admin_body_path(3)

        expect(page.at_css('h1').text).to eq('Edit public body')
        expect(field_value(translation_field(:es, :name))).
          to eq('El Department for Humpadinking')
        expect(field_value('public_body[name]')).
          to eq('Department for Humpadinking')
      end

      context 'when passed a change request id as a param' do
        let(:change_request) { FactoryBot.create(:update_body_request) }

        before do
          get edit_admin_body_path(change_request.public_body_id,
                                   change_request_id: change_request.id)
        end

        it 'should populate the email address and last edit comment on ' \
           'the public body' do
          expect(field_value('public_body[request_email]')).
            to eq(change_request.public_body_email)
          expect(field_text('public_body[last_edit_comment]')).
            to match('Notes: Please')
        end

        it 'should show a default response text' do
          expect(page.at_css('#change_request_user_response_field').text).
            to match('Thanks for your suggestion to update the email address')
        end
      end
    end

    describe 'PUT update' do
      let(:body) do
        body = FactoryBot.create(:public_body)
        AlaveteliLocalization.with_locale('es') do
          body.name = 'Los Quango'
          body.save!
        end
        body
      end

      let(:params) do
        { public_body: { name: 'Renamed',
                         short_name: body.short_name,
                         request_email: body.request_email,
                         tag_string: body.tag_string,
                         last_edit_comment: 'From test code',
                         translations_attributes: {
                           'es' => { id: body.translation_for(:es).id,
                                     locale: 'es',
                                     title: body.name(:es) }
                         } } }
      end

      context 'on success' do
        it 'saves edits to a public body heading' do
          put admin_body_path(body), params: params
          expect(PublicBody.find(body.id).name).to eq('Renamed')
        end

        it 'notifies the admin that the body was updated' do
          put admin_body_path(body), params: params
          expect(flash[:notice]).to eq('PublicBody was successfully updated.')
        end

        it 'redirects to the admin page of the body it found' do
          put admin_body_path(body), params: params
          expect(response).to redirect_to(admin_body_path(body))
        end
      end

      context 'on success for multiple locales' do
        it 'saves edits to a public body heading in another locale' do
          expect(body.name(:es)).to eq('Los Quango')
          put admin_body_path(body), params: {
            public_body: {
              name: body.name(:en),
              translations_attributes: {
                'es' => {
                  id: body.translation_for(:es).id,
                  locale: 'es',
                  name: 'Renamed'
                }
              }
            }
          }

          updated = PublicBody.find(body.id)
          expect(updated.name(:es)).to eq('Renamed')
          expect(updated.name(:en)).to eq(body.name(:en))
        end

        it 'adds a new translation' do
          body.translation_for(:es).destroy
          body.reload

          put admin_body_path(body), params: {
            public_body: {
              name: body.name(:en),
              translations_attributes: {
                'es' => {
                  locale: 'es',
                  name: 'Example Public Body ES'
                }
              }
            }
          }

          expect(flash[:notice]).to include('successful')

          updated = PublicBody.find(body.id)

          AlaveteliLocalization.with_locale(:es) do
            expect(updated.name).to eq('Example Public Body ES')
          end
        end

        it 'creates a new translation for the default locale' do
          body
          AlaveteliLocalization.set_locales('es en_GB', 'en_GB')
          put admin_body_path(body), params: {
            public_body: {
              name: 'Example Public Body en_GB'
            }
          }

          updated = PublicBody.find(body.id)
          expect(updated.translations.map(&:locale)).to include(:en_GB)
        end

        it 'adds new translations' do
          body.translation_for(:es).destroy
          body.reload

          put admin_body_path(body), params: {
            public_body: {
              name: body.name(:en),
              translations_attributes: {
                'es' => {
                  locale: 'es',
                  name: 'Example Public Body ES'
                },
                'fr' => {
                  locale: 'fr',
                  name: 'Example Public Body FR'
                }
              }
            }
          }

          expect(flash[:notice]).to include('successful')

          updated = PublicBody.find(body.id)

          AlaveteliLocalization.with_locale(:es) do
            expect(updated.name).to eq('Example Public Body ES')
          end
          AlaveteliLocalization.with_locale(:fr) do
            expect(updated.name).to eq('Example Public Body FR')
          end
        end

        it 'updates an existing translation and adds a third translation' do
          put admin_body_path(body), params: {
            public_body: {
              name: body.name(:en),
              translations_attributes: {
                'es' => { id: body.translation_for(:es).id,
                          locale: 'es',
                          name: 'Renamed Example Public Body ES' },
                'fr' => { locale: 'fr',
                          name: 'Example Public Body FR' }
              }
            }
          }

          expect(flash[:notice]).to include('successful')

          updated = PublicBody.find(body.id)

          AlaveteliLocalization.with_locale(:es) do
            expect(updated.name).to eq('Renamed Example Public Body ES')
          end
          AlaveteliLocalization.with_locale(:fr) do
            expect(updated.name).to eq('Example Public Body FR')
          end
        end
      end

      context 'on failure' do
        it 'shows the form again if updating the record was unsuccessful' do
          put admin_body_path(body), params: {
            public_body: { name: '', translations_attributes: {} }
          }
          expect(response).to have_http_status(:unprocessable_content)
          expect(page.at_css('h1').text).to eq('Edit public body')
          expect(body.reload.name).not_to eq('')
        end

        it 'is rebuilt with the given params' do
          put admin_body_path(body), params: {
            public_body: {
              name: '',
              request_email: 'updated@localhost',
              translations_attributes: {}
            }
          }
          expect(field_value('public_body[request_email]')).
            to eq('updated@localhost')
        end
      end

      context 'on failure for multiple locales' do
        let(:failing_params) do
          { public_body: {
            name: '',
            translations_attributes: {
              'es' => {
                id: body.translation_for(:es).id,
                locale: 'es',
                name: 'Mi Nuevo Body'
              }
            }
          } }
        end

        it 'is rebuilt with the default locale translation' do
          put admin_body_path(body), params: failing_params
          expect(page.at_css('h1').text).to eq('Edit public body')
          expect(field_value('public_body[name]').to_s).to eq('')
        end

        it 'is rebuilt with the alternative locale translation' do
          put admin_body_path(body), params: failing_params
          expect(field_value(translation_field(:es, :name))).
            to eq('Mi Nuevo Body')
        end
      end

      context 'when the body is being updated as a result of a change ' \
              'request' do
        let!(:change_request) { FactoryBot.create(:update_body_request) }

        before do
          put admin_body_path(change_request.public_body_id), params: {
            public_body: {
              name: 'New Quango',
              short_name: '',
              request_email: 'newquango@localhost',
              last_edit_comment: 'From test code'
            },
            change_request_id: change_request.id,
            subject: 'Body update',
            response: 'Done.'
          }
        end

        it 'should send a response to the requesting user' do
          deliveries = ActionMailer::Base.deliveries
          expect(deliveries.size).to eq(1)
          mail = deliveries[0]
          expect(mail.subject).to eq('Body update')
          expect(mail.to).to eq([change_request.requester_email])
          expect(mail.body).to match(/Done./)
        end

        it 'should mark the change request as closed' do
          expect(PublicBodyChangeRequest.find(change_request.id).is_open).
            to be false
        end
      end
    end

    describe 'DELETE destroy' do
      it 'does not destroy a public body that has associated requests' do
        id = public_bodies(:humpadink_public_body).id
        n = PublicBody.count
        delete admin_body_path(id)
        expect(response).to redirect_to(admin_body_path(id))
        expect(PublicBody.count).to eq(n)
      end

      it 'destroys a public body' do
        n = PublicBody.count
        delete admin_body_path(public_bodies(:forlorn_public_body))
        expect(response).to redirect_to admin_bodies_path
        expect(PublicBody.count).to eq(n - 1)
      end
    end

    describe 'import_csv' do
      describe 'when handling a GET request' do
        it 'should get the page successfully' do
          get import_csv_admin_bodies_path
          expect(response).to be_successful
          expect(page.at_css('h1').text).
            to eq('Upload CSV of public authorities')
        end
      end

      describe 'when handling a POST request' do
        let(:file_object) { fixture_file_upload('fake-authority-type.csv') }
        let(:temp_dir) { Dir.tmpdir }

        before do
          allow(PublicBody).to receive(:import_csv).and_return([[], []])
        end

        it 'should handle a nil csv file param' do
          post import_csv_admin_bodies_path, params: { commit: 'Dry run' }
          expect(response).to be_successful
          expect(PublicBody).not_to have_received(:import_csv)
        end

        describe 'if there is a csv file param' do
          # The dry run keeps the file for the real run.
          after do
            name = field_value('temporary_csv_file')
            FileUtils.rm_f(File.join(temp_dir, name)) if name.present?
          end

          it 'should show the original filename' do
            post import_csv_admin_bodies_path,
                 params: { csv_file: file_object, commit: 'Dry run' }
            expect(field_value('original_csv_file')).
              to eq('fake-authority-type.csv')
            expect(page.text).to include('fake-authority-type.csv')
          end

          it 'should show the temporary filename' do
            post import_csv_admin_bodies_path,
                 params: { csv_file: file_object, commit: 'Dry run' }
            temporary_filename = field_value('temporary_csv_file')
            expect(temporary_filename).
              to match(/csv_upload-#{Time.zone.now.strftime("%Y%m%d")}-\d{1,5}/)
          end
        end

        describe 'if there is no csv file param, but there are ' \
                 'temporary_csv_file and original_csv_file params' do
          let(:path) { File.join(temp_dir, 'csv_upload-20461231-394') }

          after { FileUtils.rm_f(path) }

          it 'should try and get the file contents from a temporary file ' \
             'whose name is passed as a param' do
            temp_name = File.basename(path)
            File.write(path, "#name,request_email\nA Body,a@example.com\n")
            post import_csv_admin_bodies_path,
                 params: {
                   temporary_csv_file: temp_name,
                   original_csv_file: 'original_contents.txt',
                   commit: 'Dry run'
                 }
            expect(PublicBody).to have_received(:import_csv).
              with("#name,request_email\nA Body,a@example.com\n",
                   any_args)
            expect(File).not_to exist(path)
          end

          it 'should raise an error on an invalid temp file name' do
            params = { temporary_csv_file: 'bad_name',
                       original_csv_file: 'original_contents.txt',
                       commit: 'Dry run' }
            expected_error = 'Invalid filename in upload_csv: bad_name'
            expect {
              post import_csv_admin_bodies_path, params: params
            }.to raise_error(expected_error)
          end

          it 'should raise an error if the temp file does not exist' do
            temp_name = 'csv_upload-20461231-394'
            params = { temporary_csv_file: temp_name,
                       original_csv_file: 'original_contents.txt',
                       commit: 'Dry run' }
            expected_error =
              'Missing file in upload_csv: csv_upload-20461231-394'
            expect {
              post import_csv_admin_bodies_path, params: params
            }.to raise_error(expected_error)
          end
        end
      end
    end
  end

  describe 'when administering public bodies and paying attention to ' \
           'authentication' do
    include_context 'consider all requests remote'

    let(:basic_auth) { { 'HTTP_AUTHORIZATION' => '' } }

    before do
      allow(AlaveteliConfiguration).to receive(:skip_admin_auth).
        and_return(false)
    end

    def basic_auth_header(username = 'test-basic-user',
                          password = 'test-basic-password')
      { 'HTTP_AUTHORIZATION' =>
          'Basic ' + Base64.encode64("#{username}:#{password}") }
    end

    def setup_emergency_credentials(username, password)
      allow(AlaveteliConfiguration).to receive(:skip_admin_auth).
        and_return(false)
      allow(AlaveteliConfiguration).to receive(:admin_username).
        and_return(username)
      allow(AlaveteliConfiguration).to receive(:admin_password).
        and_return(password)
    end

    def expect_signed_in
      expect(response).to have_http_status(:redirect)
      expect(response.location).not_to include(signin_path)
    end

    def expect_sign_in_asked
      expect(response).to redirect_to(signin_path)
    end

    it 'disallows non-authenticated users to do anything' do
      n = PublicBody.count
      delete admin_body_path(3), headers: basic_auth
      expect_sign_in_asked
      expect(PublicBody.count).to eq(n)
      expect(session[:using_admin]).to eq(nil)
    end

    it 'requires full authentication even when SKIP_ADMIN_AUTH is set' do
      allow(AlaveteliConfiguration).to receive(:skip_admin_auth).
        and_return(true)
      n = PublicBody.count
      delete admin_body_path(public_bodies(:forlorn_public_body)),
             headers: basic_auth
      expect(PublicBody.count).to eq(n)
      expect_sign_in_asked
    end

    it "doesn't let people with bad emergency account credentials log in" do
      setup_emergency_credentials('biz', 'fuz')
      n = PublicBody.count
      delete admin_body_path(public_bodies(:forlorn_public_body)),
             headers: basic_auth_header('baduser', 'badpassword')
      expect_sign_in_asked
      expect(PublicBody.count).to eq(n)
      expect(session[:using_admin]).to eq(nil)
    end

    [false, true].each do |disabled|
      it 'rejects configured emergency credentials with ' \
         "DISABLE_EMERGENCY_USER=#{disabled}" do
        setup_emergency_credentials('biz', 'fuz')
        allow(AlaveteliConfiguration).
          to receive(:disable_emergency_user).and_return(disabled)

        get admin_body_path(public_bodies(:humpadink_public_body),
                            emergency: '1'),
            headers: basic_auth_header('biz', 'fuz')
        expect_sign_in_asked
        expect(session[:using_admin]).to be_nil
        expect(session[:admin_name]).to be_nil

        expect do
          delete admin_body_path(public_bodies(:forlorn_public_body),
                                 emergency: '1'),
                 headers: basic_auth_header('biz', 'fuz')
        end.not_to change(PublicBody, :count)
        expect_sign_in_asked
        expect(session[:using_admin]).to be_nil
        expect(session[:admin_name]).to be_nil
      end
    end

    it 'allows superusers to do stuff' do
      sign_in users(:admin_user)
      n = PublicBody.count
      delete admin_body_path(public_bodies(:forlorn_public_body)),
             headers: basic_auth
      expect(PublicBody.count).to eq(n - 1)
      get admin_bodies_path
      expect(signed_in_as).to eq(users(:admin_user).name)
    end

    it "doesn't allow non-superusers to do stuff" do
      sign_in users(:robin_user)
      expect_signed_in
      n = PublicBody.count
      delete admin_body_path(public_bodies(:forlorn_public_body)),
             headers: basic_auth
      expect(response).to have_http_status(:not_found)
      expect(PublicBody.count).to eq(n)
      expect(session[:using_admin]).to eq(nil)
    end

    describe 'when asked for the admin current user' do
      let(:body) { public_bodies(:humpadink_public_body) }

      it 'does not assign an admin name from emergency credentials' do
        setup_emergency_credentials('biz', 'fuz')
        put admin_body_path(body, emergency: 1),
            params: { public_body: { name: 'Renamed by emergency' } },
            headers: basic_auth_header('biz', 'fuz')
        expect_sign_in_asked
        expect(body.reload.name).not_to eq('Renamed by emergency')
      end

      it 'records the current user url_name for a superuser' do
        sign_in users(:admin_user)
        put admin_body_path(body),
            params: { public_body: { name: body.name,
                                     last_edit_comment: 'Checked' } },
            headers: basic_auth
        expect(response).to redirect_to(admin_body_path(body))
        expect(body.reload.versions.last.last_edit_editor).
          to eq(users(:admin_user).url_name)
      end

      it 'does not trust REMOTE_USER when skipping admin auth' do
        allow(AlaveteliConfiguration).to receive(:skip_admin_auth).
          and_return(true)
        put admin_body_path(body),
            params: { public_body: { name: 'Renamed by remote user' } },
            headers: basic_auth,
            env: { 'REMOTE_USER' => 'i_am_admin' }
        expect_sign_in_asked
        expect(body.reload.name).not_to eq('Renamed by remote user')
      end
    end
  end
end
