require 'open3'

# Run in fresh processes so Rails and the app's worker adapter cannot
# influence the gems' specs during a root or parallel rehearsal run.
RSpec.describe 'The standalone parser gems' do
  %w[office_package pdf_redactor].each do |name|
    it "passes the #{name} suite" do
      dir = File.expand_path("../../gems/#{name}", __dir__)
      output, status = Open3.capture2e(
        RbConfig.ruby, Gem.bin_path('rspec-core', 'rspec'), chdir: dir
      )
      expect(status).to be_success, output
    end
  end
end
