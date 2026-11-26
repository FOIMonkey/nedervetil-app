require 'spec_helper'
require 'integration/alaveteli_dsl'

# What jQuery UJS did, now done by the confirm, method-link, form-lock and
# announcement-dismiss controllers the layouts load on every page.
RSpec.describe 'Rails behaviours without jQuery UJS', js: true do
  let(:admin) { FactoryBot.create(:admin_user) }

  describe 'data-confirm on a submit button' do
    let!(:announcement) { FactoryBot.create(:announcement) }

    it 'sends nothing when the answer is no' do
      using_session(login(admin)) do
        visit edit_admin_announcement_path(announcement)
        dismiss_confirm('Are you sure?') do
          click_button 'Destroy announcement'
        end
        expect(page).to have_button('Destroy announcement')
        expect(Announcement.exists?(announcement.id)).to be true
      end
    end

    it 'sends the form when the answer is yes' do
      using_session(login(admin)) do
        visit edit_admin_announcement_path(announcement)
        accept_confirm('Are you sure?') do
          click_button 'Destroy announcement'
        end
        expect(page).to have_current_path(admin_announcements_path)
        expect(Announcement.exists?(announcement.id)).to be false
      end
    end
  end

  describe 'a data-method link with data-confirm' do
    let!(:rule) { FactoryBot.create(:info_request_censor_rule) }
    let(:question) { 'Destroying a censor rule is permanent. Are you sure?' }

    it 'sends a DELETE with the token once confirmed' do
      using_session(login(admin)) do
        visit edit_admin_censor_rule_path(rule)
        accept_confirm(question) do
          click_link 'Destroy censor rule'
        end
        expect(page).to have_current_path(admin_request_path(rule.censorable))
        expect(CensorRule.exists?(rule.id)).to be false
      end
    end

    it 'stays put when the answer is no' do
      using_session(login(admin)) do
        visit edit_admin_censor_rule_path(rule)
        dismiss_confirm(question) do
          click_link 'Destroy censor rule'
        end
        expect(page).to have_link('Destroy censor rule')
        expect(CensorRule.exists?(rule.id)).to be true
      end
    end
  end

  describe 'data-disable-with' do
    let!(:announcement) { FactoryBot.create(:announcement) }

    it 'locks a submitting form’s button with its waiting words' do
      using_session(login(admin)) do
        visit edit_admin_announcement_path(announcement)
        # Into a frame, so the page stays to be looked at.
        page.execute_script(<<~JS)
          const frame = document.createElement('iframe')
          frame.name = 'sink'
          document.body.appendChild(frame)
          document.querySelector('form.form-inline').target = 'sink'
        JS
        button = find_button('Destroy announcement')
        page.execute_script(
          "arguments[0].setAttribute('data-disable-with', 'Destroying…')",
          button
        )
        accept_confirm { button.click }
        expect(page).to have_button('Destroying…', disabled: true)
      end
    end

    it 'leaves a form some other listener stopped usable' do
      using_session(login(admin)) do
        visit edit_admin_announcement_path(announcement)
        page.execute_script(<<~JS)
          document.addEventListener('submit', (event) => event.preventDefault())
        JS
        accept_confirm { click_button 'Destroy announcement' }
        sleep 0.1
        expect(page).to have_button('Destroy announcement', disabled: false)
      end
    end
  end

  describe 'dismissing announcements in the background' do
    around { |example| with_forgery_protection { example.run } }

    it 'hides the site-wide announcement without leaving the page' do
      user = FactoryBot.create(:user)
      announcement = FactoryBot.create(:announcement)
      using_session(login(user)) do
        visit help_about_path
        within('#standard-popup') { click_button(class: 'popup__close') }
        expect(page).to have_no_css('#standard-popup', visible: :visible)
        expect(page).to have_current_path(help_about_path)
        expect(eventually { announcement.dismissals.exists?(user: user) }).
          to be true
      end
    end

    it 'hides an announcement on the admin summary' do
      admin
      announcement = FactoryBot.create(:announcement, visibility: 'admin')
      using_session(login(admin)) do
        visit admin_general_index_path
        expect(page).to have_content(announcement.content)
        within('.alert-dismissible') { click_button(class: 'close') }
        expect(page).to have_no_content(announcement.content)
        expect(eventually { announcement.dismissals.exists?(user: admin) }).
          to be true
      end
    end
  end
end
