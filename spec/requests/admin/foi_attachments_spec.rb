require 'spec_helper'

RSpec.describe 'Admin attachment pages', type: :request do
  let(:admin_user) { FactoryBot.create(:admin_user) }

  before { sign_in(admin_user) }

  let(:info_request) { FactoryBot.create(:info_request, :with_plain_incoming) }
  let(:incoming_message) { info_request.incoming_messages.first }
  let!(:attachment) { incoming_message.foi_attachments.first }

  let(:page) { Nokogiri::HTML(response.body) }

  describe 'GET edit' do
    it 'shows the edit page for the attachment' do
      get edit_admin_foi_attachment_path(attachment)
      expect(response).to be_successful
      expect(page.at_css('h1').text).to eq("Attachment #{attachment.id}")
      prominence_path = admin_foi_attachment_prominence_path(attachment)
      expect(page.at_css("form[action='#{prominence_path}']")).to be_present
    end

    it 'offers only requester_only and hidden for a requester_only file' do
      get edit_admin_foi_attachment_path(attachment)

      select = page.at_css('#foi_attachment_prominence')
      expect(select.css('option').map { |opt| opt['value'] }).
        to eq(%w[requester_only hidden])
      expect(select.at_css('option[selected]')['value']).
        to eq('requester_only')
    end

    it 'selects hidden for a hidden file' do
      attachment.update!(prominence: 'hidden')

      get edit_admin_foi_attachment_path(attachment)

      select = page.at_css('#foi_attachment_prominence')
      expect(select.css('option').map { |opt| opt['value'] }).
        to eq(%w[requester_only hidden])
      expect(select.at_css('option[selected]')['value']).to eq('hidden')
    end

    it 'shows a blank option first when the file is already public' do
      attachment.make_public!

      get edit_admin_foi_attachment_path(attachment)

      select = page.at_css('#foi_attachment_prominence')
      values = select.css('option').map { |opt| opt['value'] }
      expect(values).to eq(['', 'requester_only', 'hidden'])
      expect(select.at_css('option[selected]')).to be_nil
    end

    it 'shows no document manage link when no document exists' do
      get edit_admin_foi_attachment_path(attachment)

      prominence_path = admin_foi_attachment_prominence_path(attachment)
      form = page.at_css("form[action='#{prominence_path}']")
      expect(form.css('a[href^="/documents/"]')).to be_empty
    end

    it 'links to the document manage page when a document exists' do
      document = Disclosures::Creation.new(
        user: admin_user, attachment: attachment,
        kind: 'decision_letter', email_text: true
      ).create!

      get edit_admin_foi_attachment_path(attachment)

      prominence_path = admin_foi_attachment_prominence_path(attachment)
      form = page.at_css("form[action='#{prominence_path}']")
      manage_path = disclosure_manage_document_path(document)
      link = form.at_css("a[href='#{manage_path}']")
      expect(link).to be_present
      expect(link.text).to eq(document.title)
    end

    it 'hides the document manage link when the file is erased' do
      Disclosures::Creation.new(
        user: admin_user, attachment: attachment,
        kind: 'decision_letter', email_text: true
      ).create!
      expect(attachment.erase(editor: admin_user, reason: 'Synthetic')).
        to be(true)

      get edit_admin_foi_attachment_path(attachment)

      expect(response).to be_successful
      prominence_path = admin_foi_attachment_prominence_path(attachment)
      form = page.at_css("form[action='#{prominence_path}']")
      expect(form.css('a[href^="/documents/"]')).to be_empty
    end

    it 'hides the document manage link when masking has failed' do
      Disclosures::Creation.new(
        user: admin_user, attachment: attachment,
        kind: 'decision_letter', email_text: true
      ).create!
      attachment.update!(masking_failed_at: Time.zone.now)

      get edit_admin_foi_attachment_path(attachment)

      prominence_path = admin_foi_attachment_prominence_path(attachment)
      form = page.at_css("form[action='#{prominence_path}']")
      expect(form.css('a[href^="/documents/"]')).to be_empty
    end

    it 'escapes the unmasked message body shown on the edit page' do
      expect(attachment).to be_main_body_part
      allow_any_instance_of(FoiAttachment).to receive(:unmasked_body).
        and_return('<img src=x onerror=alert(1)>')
      get edit_admin_foi_attachment_path(attachment)
      expect(response.body).to include('&lt;img src=x onerror=alert(1)&gt;')
      expect(page.css('img[src="x"]')).to be_empty
    end

    context 'when masking hit a fault on the file' do
      it 'offers the original to download' do
        attachment.update!(masking_failed_at: Time.zone.now)
        allow_any_instance_of(FoiAttachment).to receive(:masking_fault).
          and_return([:as_it_came, 'PDFRedactor::Error: synthetic'])

        get edit_admin_foi_attachment_path(attachment)

        link = page.at_xpath("//a[text()='Download the original']")
        expect(link['href']).
          to eq(download_unmasked_admin_foi_attachment_path(attachment))
      end
    end

    context 'when parts of the file went out as they came' do
      it 'lists them under Masking' do
        allow_any_instance_of(FoiAttachment).
          to receive(:unmasked_parts).and_return(['the PDF needs a password'])

        get edit_admin_foi_attachment_path(attachment)

        expect(page.css('#unmasked-parts li').map(&:text)).
          to include('the PDF needs a password')
      end

      it 'says nothing when there are none' do
        get edit_admin_foi_attachment_path(attachment)
        expect(page.at_css('#unmasked-parts')).to be_nil
      end
    end
  end

  describe 'GET download_unmasked' do
    let(:download_path) do
      download_unmasked_admin_foi_attachment_path(attachment)
    end

    # A refusal must come from the rules, not from a sign-in that failed.
    def expect_signed_in_as_admin
      get edit_admin_foi_attachment_path(attachment)
      expect(response).to have_http_status(:ok)
    end

    it 'gives an admin the original once masking hit a fault' do
      attachment.update!(masking_failed_at: Time.zone.now)
      allow(Rails.logger).to receive(:warn).and_call_original
      expect(Rails.logger).to receive(:warn).
        with(/admin original attachment download attachment=#{attachment.id}/)

      get download_path

      expect(response).to be_successful
      expect(response.body).to eq(attachment.unmasked_body)
      expect(response.media_type).to eq('application/octet-stream')
      expect(response.headers['Content-Disposition']).to include('attachment;')
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(response.headers['X-Content-Type-Options']).to eq('nosniff')
      expect(response.headers['Content-Security-Policy']).
        to eq(FileDelivery::DOCUMENT_CSP)
      expect(response.headers['X-Robots-Tag']).to include('noindex')
    end

    it 'refuses the original when masking had no fault' do
      expect_signed_in_as_admin
      get download_path
      expect(response).to have_http_status(:not_found)
    end

    it 'refuses an erased original' do
      expect_signed_in_as_admin
      attachment.update_columns(masking_failed_at: Time.zone.now,
                                erased_at: Time.zone.now)

      get download_path
      expect(response).to have_http_status(:not_found)
    end

    it 'refuses the original once the raw email is erased' do
      attachment.update!(masking_failed_at: Time.zone.now)
      allow_any_instance_of(FoiAttachment).to receive(:raw_email_erased?).
        and_return(true)

      expect_signed_in_as_admin
      get download_path
      expect(response).to have_http_status(:not_found)
    end

    it 'refuses a download without permission for the request' do
      attachment.update!(masking_failed_at: Time.zone.now)
      expect_signed_in_as_admin
      allow_any_instance_of(Admin::FoiAttachmentsController).
        to receive(:can?).and_call_original
      allow_any_instance_of(Admin::FoiAttachmentsController).
        to receive(:can?).with(:admin, info_request).and_return(false)

      get download_path
      expect(response).to have_http_status(:not_found)
    end
  end
end
