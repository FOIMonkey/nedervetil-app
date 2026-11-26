# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = 'pdf_redactor'
  spec.version = '0.1.0'
  spec.authors = ['Nedervetil contributors']
  spec.summary = 'Read and redact PDF text, images and metadata'
  spec.required_ruby_version = '>= 3.4'
  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*'].select { |path| File.file?(path) }
  end
end
