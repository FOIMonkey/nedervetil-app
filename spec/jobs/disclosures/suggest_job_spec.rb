require 'spec_helper'

# Converters may run only after a person acts. Suggestions are made without
# anyone asking, so they read only core's own text.
RSpec.describe Disclosures::SuggestJob do
  around do |example|
    with_setting(Disclosures, :ocr, true) { example.run }
  end

  it 'starts no rendering, conversion or OCR program, even for a scan with OCR on' do
    renderers = %w[pdftoppm pdfimages tesseract
                   soffice libreoffice magick convert]
    info_request = FactoryBot.create(:info_request)
    sheet = { name: 'Figures', rows: [%w[Ward Repairs], ['North', 12]] }
    message = AttachmentFixtures.deliver(
      info_request,
      [
        ['response.pdf',
         'application/pdf',
         DocumentFixtures.scanned_pdf(lines: ['Dear Requester,',
                                              'We hold the information.'])],
        ['figures.xlsx',
         'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
         DocumentFixtures.xlsx(sheets: [sheet])],
        ['records.zip', 'application/zip',
         DocumentFixtures.zip('repairs.csv' => "Ward,Repairs\nNorth,12\n")],
        ['signature.png', 'image/png', DocumentFixtures.signature_png]
      ]
    )
    commands = []
    allow_any_instance_of(ExternalCommand).
      to receive(:run).and_wrap_original do |run, *args|
        command = run.receiver
        commands << [command.instance_variable_get(:@cmd),
                     *command.instance_variable_get(:@args)].map(&:to_s)
        run.call(*args)
      end

    described_class.perform_now(message.id)

    expect(commands.flatten.map { |arg| File.basename(arg) } & renderers).
      to be_empty
    expect(commands.flatten).not_to include('-bbox-layout')
    rules = Disclosures::Suggestion.where(incoming_message_id: message.id).
      pluck(:display_name, :rule).to_h
    expect(rules).to include('response.pdf' => 'no_text',
                             'figures.xlsx' => 'spreadsheet',
                             'records.zip' => 'format',
                             'signature.png' => 'format')
    expect(rules.values).to include('email_with_scan')
  end
end
