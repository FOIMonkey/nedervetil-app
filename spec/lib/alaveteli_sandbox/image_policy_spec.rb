require 'spec_helper'

# The listings are `magick -list policy` as ImageMagick 7.1.1 prints it: under
# the required policy, and under the one Debian installs.
RSpec.describe AlaveteliSandbox::ImagePolicy do
  let(:required) do
    file_fixture('imagemagick-policy-listing-required.txt').read
  end
  let(:debian) { file_fixture('imagemagick-policy-listing-debian.txt').read }

  def with(listing, policy)
    "#{listing}\nPath: /usr/etc/ImageMagick-7/policy.xml\n#{policy}"
  end

  describe '.required' do
    it 'is every entry of the policy file that says what may be done' do
      expect(described_class.required).to eq(
        [['delegate', ['none'], '*'],
         ['filter', ['none'], '*'],
         ['path', ['none'], '@*'],
         ['path', ['none'], '|*'],
         ['module', ['none'], '*'],
         ['module', %w[read write], '{PNG,JPEG,GIF,BMP,TIFF,WEBP,PDF,INFO}'],
         ['coder', ['none'], '*'],
         ['coder', %w[read write],
          '{PNG,PNG8,PNG24,PNG32,PNG48,PNG64,JPEG,JPG,JPE,GIF,BMP,BMP2,BMP3,' \
          'TIFF,TIFF64,WEBP}'],
         ['coder', ['write'], '{PDF,INFO}']]
      )
    end
  end

  describe '.problem' do
    it 'is nil under the required policy' do
      expect(described_class.problem(required)).to be_nil
    end

    it 'is nil when only the resource limits differ' do
      listing = required.sub('value: 512MiB', 'value: 256MiB')
      expect(listing).not_to eq(required)
      expect(described_class.problem(listing)).to be_nil
    end

    it 'reports Debian’s policy, which allows delegates and every coder' do
      problem = described_class.problem(debian)
      expect(problem).to include(
        'is not imagemagick-policy.xml: it is without delegate none *; ' \
        'filter none *; path none |*; module none *;'
      )
      expect(problem).to match(/, and with coder none URL/)
    end

    it 'reports a coder another policy file allows' do
      listing = with(required, <<~POLICY)
        Policy: Coder
          rights: Read Write
          pattern: {SVG,MVG}
      POLICY
      expect(described_class.problem(listing)).
        to end_with('it is with coder read|write {SVG,MVG}')
    end

    it 'reports a delegate another policy file allows' do
      listing = with(required, <<~POLICY)
        Policy: Delegate
          rights: Execute
          pattern: gs
      POLICY
      expect(described_class.problem(listing)).
        to end_with('it is with delegate execute gs')
    end

    it 'reports a coder given more than the required policy gives it' do
      listing = required.sub("rights: Write \n", "rights: Read Write \n")
      expect(described_class.problem(listing)).to end_with(
        'it is without coder write {PDF,INFO}, and with coder read|write ' \
        '{PDF,INFO}'
      )
    end

    it 'reports a path or a module given more than the required policy' do
      listing = required.sub("rights: None \n    pattern: @*",
                             "rights: Read Write \n    pattern: @*")
      expect(described_class.problem(listing)).to end_with(
        'it is without path none @*, and with path read|write @*'
      )

      listing = required.sub('pattern: {PNG,JPEG,GIF,BMP,TIFF,WEBP,PDF,INFO}',
                             'pattern: {PNG,JPEG,SVG}')
      expect(described_class.problem(listing)).
        to end_with('and with module read|write {PNG,JPEG,SVG}')
    end

    it 'reports a listing that isn’t one' do
      expect(described_class.problem('')).to match(/without delegate none/)
    end
  end
end
