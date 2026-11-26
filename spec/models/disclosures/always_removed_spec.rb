require 'spec_helper'

RSpec.describe 'Pages holding a sign-in link or the reply address' do
  let(:requester) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:info_request) { FactoryBot.create(:info_request, user: requester) }
  let(:login_link) do
    "https://#{AlaveteliConfiguration.domain}/c/Synthetic0Token"
  end

  describe Disclosures::Masking, '.always_removed?' do
    def found?(text)
      described_class.always_removed?(text)
    end

    let(:id) { info_request.id }
    let(:hash) { InfoRequest.hash_from_id(id) }

    it 'finds a sign-in link in any case, without its scheme, with www. or ' \
       'with a space after /c/' do
      domain = AlaveteliConfiguration.domain
      ["See #{login_link}", "See #{login_link.upcase}", "#{domain}/c/Tok3n",
       "www.#{domain}/c/Tok3n", "#{domain}/c/ Tok3n"].each do |text|
        expect(found?(text)).to be(true), text
      end
    end

    it 'finds a reply address as core reads one: any case, prefix or ' \
       'domain, l and o for 1 and 0' do
      [info_request.incoming_email,
       info_request.incoming_email.upcase,
       "Request-#{id}-#{hash}@another.example",
       "foi+request-#{id}-#{hash.tr('10', 'lo')}@x.test"].each do |text|
        expect(found?(text)).to be(true), text
      end
    end

    it 'finds one broken across lines, spaced out or written with other ' \
       'hyphens or hidden characters' do
      ["request-\n#{id}-#{hash}@x.test",
       "requ\u00AD\nest-#{id}-#{hash}",
       "request - #{id} - #{hash}",
       "request\u2011#{id}\u2010#{hash}",
       "request\u2013#{id}-#{hash}",
       "request-#{id}-\u200B#{hash}"].each do |text|
        expect(found?(text)).to be(true), text.inspect
      end
    end

    it 'finds another request’s address too, but not a wrong hash' do
      other = id + 1
      expect(found?("request-#{other}-#{InfoRequest.hash_from_id(other)}")).
        to be(true)
      expect(found?("request-#{id}-00000000@x.test")).to be(false)
    end

    it 'leaves other links and addresses to the other masks' do
      expect(found?("https://#{AlaveteliConfiguration.domain}/request/1 " \
                    'foi@synthetic-authority.test')).to be(false)
    end
  end
end
