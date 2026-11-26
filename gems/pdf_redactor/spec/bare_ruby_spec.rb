require_relative 'spec_helper'

RSpec.describe 'pdf_redactor in bare Ruby' do
  it 'processes a document without loading the application' do
    page = { texts: [{ text: 'Zebracorn', x: 40, y: 80 }] }
    pdf = AttachmentFixtures.pdf(pages: [page])
    script = <<~RUBY
      require 'pdf_redactor'
      rule = PDFRedactor::Rule.new(/Zebracorn/, true, nil, 'Zebracorn')
      masked, report = PDFRedactor.redact(STDIN.binmode.read, [rule], final_scan: true)
      abort 'mask failed' unless masked.start_with?('%PDF') && report['rules_matched'] == [0]
      if defined?(Rails) || defined?(ActiveSupport) || defined?(AlaveteliSandbox)
        abort 'application loaded'
      end
    RUBY
    _, errors, status = Open3.capture3(
      { 'PATH' => ENV.fetch('PATH') }, RbConfig.ruby, '--disable-gems',
      '-I', File.expand_path('../lib', __dir__), '-e', script,
      stdin_data: pdf, unsetenv_others: true
    )
    expect(status).to be_success, errors
  end
end
