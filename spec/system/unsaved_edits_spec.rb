require 'spec_helper'
require 'integration/alaveteli_dsl'

# The box and text editors keep unsaved edits only on the page, so leaving it
# with some asks first (editor/unsaved_work.js). Nothing is sent anywhere.
RSpec.describe 'Leaving the editors with unsaved edits', js: true do
  include DisclosuresHelpers

  let(:leave) { 'Leave with unfinished edits? They have not been applied.' }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request) }
  let(:message) do
    AttachmentFixtures.deliver(
      info_request,
      [['notes.txt', 'text/plain',
        "Name: Alice Synthetic\nPhone: 01632 960123\n"],
       ['notice.png', 'image/png',
        AttachmentFixtures.image(lines: [[40, 100, 'Notice to Alice']])]]
    )
  end

  def attachment(name)
    message.get_attachments_for_display.find { |part| part.filename == name }
  end

  # A confirm the page shows is recorded where the next page can read it.
  def record_confirms
    page.execute_script(<<~JS)
      window.confirm = function (text) {
        sessionStorage.setItem('confirmed', text);
        return true;
      };
    JS
  end

  def recorded_confirm
    page.evaluate_script("sessionStorage.getItem('confirmed')")
  end

  [false, true].each do |pro|
    context "with Pro #{pro ? 'on' : 'off'}", feature: { alaveteli_pro: pro } do
      it 'asks before a link leaves typed text, and stays when told to' do
        notes = attachment('notes.txt')
        using_session(login(admin)) do
          visit manage_attachment_text_path(notes)
          fill_in 'text', with: "Name: [redacted]\nPhone: 01632 960123\n"

          dismiss_confirm(leave) { click_link 'Back to the attachment' }
          expect(page).to have_current_path(manage_attachment_text_path(notes))
          expect(find_field('text').value).to include('Name: [redacted]')

          accept_confirm(leave) { click_link 'Back to the attachment' }
          expect(page).to have_current_path(manage_attachment_path(notes))
        end
      end

      it 'leaves without asking when nothing has changed' do
        notes = attachment('notes.txt')
        using_session(login(admin)) do
          visit manage_attachment_text_path(notes)
          record_confirms
          click_link 'Back to the attachment'
          expect(page).to have_current_path(manage_attachment_path(notes))
          expect(recorded_confirm).to be_nil
        end
      end

      it 'saves typed text without asking' do
        notes = attachment('notes.txt')
        using_session(login(admin)) do
          visit manage_attachment_text_path(notes)
          fill_in 'text', with: "Name: [redacted]\nPhone: 01632 960123\n"
          record_confirms
          click_button 'Save as a draft'
          expect(page).to have_no_current_path(
            manage_attachment_text_path(notes)
          )
          expect(recorded_confirm).to be_nil
        end
      end

      it 'asks before a link leaves a box that has not been made' do
        png = attachment('notice.png')
        using_session(login(admin)) do
          visit manage_attachment_redact_path(png)
          find('[data-add-box]').click
          expect(page).to have_css('.redaction-box')

          dismiss_confirm(leave) { click_link 'Back to the attachment' }
          expect(page).to have_current_path(manage_attachment_redact_path(png))
          expect(page).to have_css('.redaction-box')
        end
      end
    end
  end
end
