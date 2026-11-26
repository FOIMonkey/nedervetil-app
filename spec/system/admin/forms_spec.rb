require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'Admin form helpers', js: true do
  let(:admin) { FactoryBot.create(:admin_user) }

  describe 'holidays' do
    let!(:holiday) { FactoryBot.create(:holiday) }

    it 'opens the new form in place' do
      using_session(login(admin)) do
        visit admin_holidays_path
        click_link 'New holiday'
        expect(page).to have_css('form.new-holiday-form')
        expect(page).to have_current_path(admin_holidays_path)
      end
    end

    it 'opens a holiday’s edit form in its row' do
      using_session(login(admin)) do
        visit admin_holidays_path
        within("##{ActionView::RecordIdentifier.dom_id(holiday)}") do
          click_link 'Edit'
          expect(page).to have_css('form.edit-holiday-form')
          expect(page).to have_button('Destroy')
        end
        expect(page).to have_current_path(admin_holidays_path)
      end
    end

    it 'takes a feed URL only when the feed is the source' do
      using_session(login(admin)) do
        visit new_admin_holiday_import_path
        choose 'Built-in suggestions'
        expect(page).
          to have_field('holiday_import[ical_feed_url]', disabled: true)
        choose 'iCal feed'
        expect(page).
          to have_field('holiday_import[ical_feed_url]', disabled: false)
      end
    end

    it 'leaves a suggested holiday out of an import' do
      allow(AlaveteliConfiguration).
        to receive(:iso_country_code).and_return('GB')
      using_session(login(admin)) do
        visit new_admin_holiday_import_path
        choose 'Built-in suggestions'
        click_button 'Show holidays'
        count = all('.import-holiday-info').size
        skip 'no built-in suggestions in this environment' if count.zero?

        first('.import-holiday-info').click_button('Remove')
        expect(page).to have_css('.import-holiday-info', count: count - 1)
        expect(page).to have_current_path(preview_admin_holiday_imports_path,
                                          ignore_query: true)
      end
    end
  end

  describe 'notes' do
    it 'shows the body field the chosen style uses' do
      body = FactoryBot.create(:public_body)
      using_session(login(admin)) do
        visit new_admin_note_path(notable_id: body.id,
                                  notable_type: 'PublicBody')
        select Note.style_labels.key('original').to_s, from: 'Style'
        expect(page).to have_css('.note--body', visible: :visible)
        expect(page).to have_no_css('.note--rich_body', visible: :visible)
        select Note.style_labels.key('red').to_s, from: 'Style'
        expect(page).to have_no_css('.note--body', visible: :visible)
        expect(page).to have_css('.note--rich_body', visible: :visible)
      end
    end
  end

  describe 'censor rules' do
    it 'puts the previous edit comment back' do
      rule = FactoryBot.create(:censor_rule,
                               last_edit_comment: 'Names of staff')
      using_session(login(admin)) do
        visit edit_admin_censor_rule_path(rule)
        expect(page).to have_field('Comment for this edit', with: '')
        click_button 'Use previous comment'
        expect(page).
          to have_field('Comment for this edit', with: 'Names of staff')
      end
    end
  end

  describe 'category order' do
    # Saving, given a changed list. Dragging itself, with the mouse, is
    # spec/system/admin/category_drag_spec.rb.
    it 'saves a new order of headings once the list changes' do
      root = PublicBody.category_root
      headings = root.tree.to_a
      skip 'needs two headings' if headings.size < 2
      using_session(login(admin)) do
        visit admin_categories_path(model_type: 'PublicBody')
        expect(page).to have_link('Save', class: 'disabled')

        page.execute_script(<<~JS)
          const list = document.getElementById('category_list')
          list.appendChild(list.firstElementChild)
          const panel = list.parentNode.querySelector(':scope > .save-panel')
          window.Stimulus.getControllerForElementAndIdentifier(panel, 'category-order').changed()
        JS

        panel = find_by_id('category_list').sibling('.save-panel')
        expect(panel).to have_text('There are unsaved changes')
        panel.click_link('Save')
        expect(panel).to have_text('Changes saved.')
        expect(panel).to have_link('Save', class: 'disabled')
        expect(eventually { root.reload.tree.first != headings.first }).
          to be true
      end
    end
  end
end
