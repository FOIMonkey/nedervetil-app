require 'spec_helper'

RSpec.describe 'Admin notes', type: :request do
  before { sign_in FactoryBot.create(:admin_user) }

  let(:page) { Nokogiri::HTML(response.body) }

  def heading
    page.at_css('.page-header h1').text
  end

  def note_form(path)
    page.at_css(%(form[action="#{path}"]))
  end

  describe 'GET index' do
    before { get admin_notes_path }

    it 'shows the notes page' do
      expect(response).to have_http_status(:ok)
      expect(heading).to eq('Notes')
    end

    it 'lists the notes newest first' do
      ids = page.css('td.id').map { |cell| cell.text.to_i }

      expect(ids.size).to be > 1
      expect(ids).to eq(ids.sort.reverse)
    end

    it 'links each listed row to its note' do
      rows = page.css('td.id')
      links = rows.map do |cell|
        cell.parent.at_css('a[href$="/edit"]')['href']
      end
      expect(links).to eq(
        rows.map { |cell| edit_admin_note_path(cell.text.to_i) }
      )
      expect(Note.where(id: rows.map { |cell| cell.text.to_i }).count).
        to eq(rows.size)
    end
  end

  describe 'GET new' do
    before { get new_admin_note_path(notable_tag: 'some_tag') }

    it 'shows the new note form for the tag' do
      expect(response).to have_http_status(:ok)
      expect(heading).to eq('New note')
      form = note_form(admin_notes_path)
      expect(form).to be_present
      expect(form.at_css('input[name="note[notable_tag]"]')['value']).
        to eq('some_tag')
    end
  end

  # The form says what a note applies to, so there is none to show for a
  # note that applies to nothing.
  describe 'a note that applies to neither a record nor a tag' do
    before do
      get admin_notes_path
      expect(response).to have_http_status(:ok)
    end

    it 'has no form' do
      get new_admin_note_path
      expect(response).to have_http_status(:not_found)
    end

    it 'is not made' do
      params = { note: { rich_body: 'Text', style: 'blue' } }

      expect { post admin_notes_path, params: params }.
        not_to change(Note, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST create' do
    shared_examples 'successful create' do
      it 'creates the note' do
        expect { post admin_notes_path, params: params }.
          to change(Note, :count).by(1)
        expect(Note.last.rich_body.to_plain_text).to eq('New body')
      end

      it 'sets a notice' do
        post admin_notes_path, params: params
        expect(flash[:notice]).to eq('Note successfully created.')
      end
    end

    context 'on a successful create of concrete note' do
      include_examples 'successful create'

      let!(:note) { FactoryBot.create(:note, :for_public_body) }
      let(:public_body) { note.notable }

      let(:params) do
        {
          note: {
            rich_body: 'New body',
            notable_id: public_body.id,
            notable_type: public_body.class.name,
            style: 'blue'
          }
        }
      end

      it 'redirects to the public body admin' do
        post admin_notes_path, params: params
        expect(Note.last.notable).to eq(public_body)
        expect(response).to redirect_to(admin_public_body_path(public_body))
      end
    end

    context 'on a successful create of tagged note' do
      include_examples 'successful create'

      let!(:note) { FactoryBot.create(:note, :tagged) }
      let(:tag) { note.notable_tag }

      let(:params) do
        { note: { rich_body: 'New body', notable_tag: tag, style: 'blue' } }
      end

      it 'redirects to the tag admin' do
        post admin_notes_path, params: params
        expect(Note.last.notable_tag).to eq(tag)
        expect(response).to redirect_to(admin_tag_path(tag))
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

      let(:params) do
        { note: { rich_body: html, notable_tag: 'some_tag', style: 'blue' } }
      end

      it 'stores the body without the attachment' do
        post admin_notes_path, params: params
        body = Note.last.rich_body
        expect(body.body.to_html).to eq('<p>Kept</p>')
        expect(body.embeds).to be_empty
      end
    end

    context 'on an unsuccessful create' do
      let(:params) do
        { note: { rich_body: '', style: '', notable_tag: 'some_tag' } }
      end

      it 'does not create the note' do
        expect { post admin_notes_path, params: params }.
          not_to change(Note, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'shows the form again' do
        post admin_notes_path, params: params
        expect(response).to have_http_status(:unprocessable_content)
        expect(heading).to eq('New note')
        expect(note_form(admin_notes_path)).to be_present
      end
    end
  end

  describe 'GET edit' do
    let!(:note) { FactoryBot.create(:note) }

    before { get edit_admin_note_path(note) }

    it 'shows the edit form for the note' do
      expect(response).to have_http_status(:ok)
      expect(heading).to eq('Edit note')
      expect(note_form(admin_note_path(note))).to be_present
    end
  end

  describe 'PATCH update' do
    let!(:note) { FactoryBot.create(:note) }

    before do
      patch admin_note_path(note), params: params
    end

    shared_examples 'successful update' do
      it 'updates the note' do
        expect(note.reload.rich_body.to_plain_text).to eq('New body')
      end

      it 'sets a notice' do
        expect(flash[:notice]).to eq('Note successfully updated.')
      end
    end

    context 'on a successful update of concrete note' do
      include_examples 'successful update'

      let!(:note) { FactoryBot.create(:note, :for_public_body) }
      let(:public_body) { note.notable }

      let(:params) do
        {
          note: {
            rich_body: 'New body',
            notable_id: public_body.id,
            notable_type: public_body.class.name,
            style: 'blue'
          }
        }
      end

      it 'redirects to the public body admin' do
        expect(response).to redirect_to(admin_public_body_path(public_body))
      end
    end

    context 'on a successful update of tagged note' do
      include_examples 'successful update'

      let!(:note) { FactoryBot.create(:note, :tagged) }
      let(:tag) { note.notable_tag }

      let(:params) do
        { note: { rich_body: 'New body', notable_tag: tag, style: 'blue' } }
      end

      it 'redirects to the tag admin' do
        expect(response).to redirect_to(admin_tag_path(tag))
      end
    end

    context 'on an unsuccessful update' do
      let(:params) do
        { note: { rich_body: '', style: '' } }
      end

      it 'does not update the note' do
        expect(note.reload.rich_body.to_plain_text).to eq('Test note')
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'shows the form for the note again' do
        expect(response).to have_http_status(:unprocessable_content)
        expect(heading).to eq('Edit note')
        expect(note_form(admin_note_path(note))).to be_present
      end
    end
  end

  describe 'DELETE destroy' do
    let!(:note) { FactoryBot.create(:note) }

    it 'destroys the note' do
      expect { delete admin_note_path(note) }.to change(Note, :count).by(-1)
      expect(Note).not_to exist(note.id)
    end

    it 'sets a notice' do
      delete admin_note_path(note)
      expect(flash[:notice]).to eq('Note successfully destroyed.')
    end

    context 'when concrete note' do
      let!(:note) { FactoryBot.create(:note, :for_public_body) }
      let(:public_body) { note.notable }

      it 'redirects to the public body admin' do
        delete admin_note_path(note)
        expect(response).to redirect_to(admin_public_body_path(public_body))
      end
    end

    context 'when tagged note' do
      let!(:note) { FactoryBot.create(:note, :tagged) }
      let(:tag) { note.notable_tag }

      it 'redirects to the tag admin' do
        delete admin_note_path(note)
        expect(response).to redirect_to(admin_tag_path(tag))
      end
    end
  end
end
