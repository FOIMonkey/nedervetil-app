require 'spec_helper'
require 'open3'

# The gems stay loaded while Rails reloads their app-side bridges. Exercise
# both together in development, where reloading is enabled.
RSpec.describe 'OfficePackage, after the app’s code is reloaded' do
  it 'still has its errors and its unpack limit' do
    script = <<~RUBY
      OfficePackage::CompoundFile
      PDFRedactor::Isolated
      Rails.application.reloader.reload!
      abort 'stale PDF adapter' unless PDFRedactor.backend == PDFRedactor::Isolated
      OfficePackage::Isolated
      puts [OfficePackage::Package, OfficePackage::Error,
            OfficePackage.limits[:total] == OfficePackage::MAX_TOTAL,
            MailHandler.mail_from_outlook('not a compound file').inspect].
        join(' ')
    RUBY
    environment = { 'RAILS_ENV' => 'development' }

    output, errors, status = Open3.capture3(
      environment, Rails.root.join('bin/rails').to_s, 'runner', script
    )

    expect(status).to be_success, errors.lines.last(5).join
    expect(output.lines.last.strip).
      to eq('OfficePackage::Package OfficePackage::Error true nil')
  end
end
