require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'The box and text editors', js: true do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:requester) do
    FactoryBot.create(:user, name: 'Alice Example',
                             email: 'alice@example.test')
  end
  let(:info_request) { FactoryBot.create(:info_request, user: requester) }
  let(:pdf) do
    AttachmentFixtures.pdf(
      pages: [AttachmentFixtures.letter_page(secret: 'Visible council records'),
              AttachmentFixtures.letter_page(secret: 'Alice Example wrote')]
    )
  end
  let(:attachment) do
    message = AttachmentFixtures.deliver(
      info_request, [['records.pdf', 'application/pdf', pdf]]
    )
    message.get_attachments_for_display.
      find { |part| part.filename == 'records.pdf' }
  end

  def boxes_field
    JSON.parse(find_by_id('redaction-boxes', visible: :all).value)
  end

  def box_count
    boxes_field.values.sum(&:size)
  end

  def mouse
    page.driver.browser.mouse
  end

  # Wait for image load; the editor refuses drawing on unloaded pages.
  def sheet_rect(number)
    sheet = find(".redaction-page[data-page='#{number}'] [data-sheet]")
    expect(page).to have_css(
      ".redaction-page[data-page='#{number}'] img.redaction-page__image"
    )
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until page.evaluate_script(<<~JS, sheet)
        (function (sheet) {
          const image = sheet.querySelector('img')
          return image.complete && image.naturalWidth > 0
        })(arguments[0])
      JS
    end
    sheet.scroll_to(sheet, align: :center)
    page.evaluate_script(<<~JS, sheet)
      (function (sheet) {
        const r = sheet.getBoundingClientRect()
        return [r.left, r.top, r.width, r.height]
      })(arguments[0])
    JS
  end

  # Coords are sheet fractions; centering only shows the middle two-thirds.
  def drag_box(number, from, to)
    left, top, width, height = sheet_rect(number)
    at = ->(x, y) { { x: left + (x * width), y: top + (y * height) } }
    mouse.move(**at.call(*from))
    mouse.down
    (1..8).each do |step|
      mouse.move(**at.call(from[0] + ((to[0] - from[0]) * step / 8.0),
                           from[1] + ((to[1] - from[1]) * step / 8.0)))
    end
    mouse.up
  end

  def press(*keys)
    page.driver.browser.keyboard.type(keys)
  end

  let(:leave) { 'Leave with unfinished edits? They have not been applied.' }

  def take_out(selector, back: true)
    page.execute_script(<<~JS, selector, back)
      const [selector, back] = arguments
      const form = document.querySelector(selector)
      const home = [form.parentNode, form.nextSibling]
      form.remove()
      if (back) { setTimeout(() => home[0].insertBefore(form, home[1]), 50) }
    JS
  end

  context 'with an admin' do
    before { attachment }

    it 'draws a box by dragging, steps back and forward, and sends it' do
      using_session(login(admin)) do
        visit manage_attachment_redact_path(attachment)
        expect(page).to have_text('No boxes yet.')

        drag_box(1, [0.2, 0.3], [0.6, 0.4])
        expect(page).to have_text('1 box in total.')
        coords = boxes_field.fetch('1').first
        expect(coords[0]).to be_within(0.02).of(0.2)
        expect(coords[1]).to be_within(0.02).of(0.3)
        expect(coords[2]).to be_within(0.02).of(0.6)
        expect(coords[3]).to be_within(0.02).of(0.4)
        expect(page).to have_css('.redaction-page[data-page="1"] ' \
                                 '.redaction-page__count', text: '1 box')

        click_button 'Undo'
        expect(page).to have_text('No boxes yet.')
        expect(boxes_field).to eq({})
        click_button 'Redo'
        expect(page).to have_text('1 box in total.')

        find('[data-zoom-in]').click
        expect(page).to have_css('[data-zoom-level]', text: '125%')
        expect(boxes_field.fetch('1').first).to eq(coords)
        click_button 'Fit width'

        click_button 'Make the redacted PDF'
        expect(page).to have_text('Making the file.')
        made = AttachmentManagement::Revision.
               where(foi_attachment_id: attachment.id).order(:id).last
        expect(made.kind).to eq('pdf_redaction')
        expect(made.instructions['boxes']).to eq('1' => [coords])
      end
    end

    it 'places, moves, sizes and removes a box with the keyboard' do
      using_session(login(admin)) do
        visit manage_attachment_redact_path(attachment)
        sheet_rect(1)
        within('.redaction-page[data-page="1"]') { click_button 'Add a box' }
        expect(page).to have_text('1 box in total.')
        expect(boxes_field).to eq('1' => [[0.3, 0.45, 0.7, 0.5]])
        expect(page).to have_css('.redaction-box.is-chosen:focus')

        press(:right)
        expect(boxes_field).to eq('1' => [[0.305, 0.45, 0.705, 0.5]])
        press(%i[shift down])
        expect(boxes_field).to eq('1' => [[0.305, 0.5, 0.705, 0.55]])
        press(%i[alt right])
        expect(boxes_field).to eq('1' => [[0.305, 0.5, 0.71, 0.55]])
        press(%i[alt down])
        expect(boxes_field).to eq('1' => [[0.305, 0.5, 0.71, 0.555]])

        find('.redaction-box').send_keys(:delete)
        expect(page).to have_text('No boxes yet.')
        press([:control, 'z'])
        expect(page).to have_text('1 box in total.')
        press([:control, :shift, 'z'])
        expect(page).to have_text('No boxes yet.')

        within('.redaction-page[data-page="2"]') { click_button 'Add a box' }
        within('.redaction-page[data-page="2"]') { click_button 'Add a box' }
        expect(page).to have_text('2 boxes in total.')
        within('.redaction-page[data-page="2"]') do
          click_button 'Remove all boxes on this page'
        end
        expect(page).to have_text('No boxes yet.')
      end
    end

    # Pages after the second load only when scrolled to.
    it 'lets boxes go on a page that loads late' do
      long_pdf = AttachmentFixtures.pdf(
        pages: (1..4).map do |n|
          AttachmentFixtures.letter_page(secret: "Page #{n} records")
        end
      )
      long = AttachmentFixtures.deliver(
        info_request, [['long.pdf', 'application/pdf', long_pdf]]
      ).get_attachments_for_display.find { |part| part.filename == 'long.pdf' }
      using_session(login(admin)) do
        visit manage_attachment_redact_path(long)
        expect(page).to have_css('form.is-ready')
        within('.redaction-page[data-page="4"]') do
          expect(page).to have_button('Add a box', disabled: false)
          expect(page).to have_css('.redaction-page__count', text: 'No boxes')
        end
        sheet_rect(4)
        within('.redaction-page[data-page="4"]') { click_button 'Add a box' }
        expect(boxes_field).to eq('4' => [[0.3, 0.45, 0.7, 0.5]])
      end
    end

    it 'starts again cleanly when its form is taken out and put back' do
      using_session(login(admin)) do
        visit manage_attachment_redact_path(attachment)
        sheet_rect(1)
        within('.redaction-page[data-page="1"]') { click_button 'Add a box' }
        expect(page).to have_text('1 box in total.')

        take_out('form[data-redaction-editor]')
        expect(page).to have_css('form.is-ready')
        expect(page).to have_css('.redaction-box', count: 1)
        expect(page).to have_css('.redaction-editor__viewport', count: 1)
        expect(page).to have_css('[data-page-jump] option', count: 2)

        within('.redaction-page[data-page="1"]') { click_button 'Add a box' }
        expect(page).to have_text('2 boxes in total.')
        expect(page).to have_css('.redaction-box', count: 2)
        dismiss_confirm(leave) { click_link 'Back to the attachment' }
        expect(page).to have_css('.redaction-box', count: 2)
      end
    end
  end

  context 'with the requester' do
    include_context 'with the publish flow off'

    it 'draws a box on an attachment' do
      message = AttachmentFixtures.deliver(
        info_request, [['notice.pdf', 'application/pdf', pdf]]
      )
      notice = message.get_attachments_for_display.
               find { |part| part.filename == 'notice.pdf' }
      using_session(login(requester)) do
        visit manage_attachment_redact_path(notice)
        drag_box(1, [0.2, 0.45], [0.5, 0.55])
        expect(page).to have_text('1 box in total.')
      end
    end
  end

  context 'with the requester in the publish flow' do
    it 'opens the PDF box editor without JS errors, draws a box, and submits' do
      message = AttachmentFixtures.deliver(
        info_request, [['notice.pdf', 'application/pdf', pdf]]
      )
      notice = message.get_attachments_for_display.
               find { |part| part.filename == 'notice.pdf' }
      doc = Disclosures::Creation.new(
        user: requester, attachment: notice, kind: 'released_records'
      ).create!

      using_session(login(requester)) do
        visit publish_reply_redact_path(
          url_title: info_request.url_title,
          message_id: message.id,
          id: doc
        )
        expect(page).to have_css('#publish-redaction.is-ready')
        expect(page).to have_css('.redaction-page[data-page="1"] [data-sheet]')

        drag_box(1, [0.2, 0.45], [0.5, 0.55])
        expect(page).to have_css('.redaction-box', count: 1)
        expect(page).to have_css('#publish-new-boxes li', count: 1)

        click_button 'Save redactions'
        expect(page).to have_current_path(
          publish_reply_check_path(url_title: info_request.url_title,
                                   message_id: message.id)
        )
        expect(notice.reload.file_blob.metadata['rasterized']).to be(true)
        applied = AttachmentManagement::Revision.
                  where(foi_attachment_id: notice.id, status: 'applied').last
        expect(applied).to be_present
        expect(applied.kind).to eq('pdf_redaction')
      end
    end

    it 'opens the text redaction toolbar and replaces selected text' do
      message = AttachmentFixtures.deliver(
        info_request, [], text: "Name: Alice Example\n"
      )
      main_part = message.get_main_body_text_part
      doc = Disclosures::Creation.new(
        user: requester, attachment: main_part, kind: 'decision_letter',
        email_text: true
      ).create!

      using_session(login(requester)) do
        visit publish_reply_redact_path(
          url_title: info_request.url_title,
          message_id: message.id,
          id: doc
        )
        field = find_by_id('document-text')
        page.execute_script(<<~JS, field)
          arguments[0].setSelectionRange(6, 19)
        JS
        click_button 'Hide'
        expect(field.value).to eq("Name: [redacted]\n")
        click_button 'Undo'
        expect(field.value).to eq("Name: Alice Example\n")
        click_button 'Redo'
        expect(field.value).to eq("Name: [redacted]\n")
      end
    end
  end
end
