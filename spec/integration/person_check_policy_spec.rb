require 'spec_helper'

# The test browser never loads Cloudflare's script, so no system spec can
# show the person check's widget working. This pins the page policy it needs:
# its nonce'd script under 'strict-dynamic', and its iframe from Cloudflare,
# which today falls back to default-src's https:.
RSpec.describe 'The page policy for the person check', type: :request do
  before do
    allow(Turnstile).to receive_messages(configured?: true,
                                         site_key: 'site-key')
  end

  def policy
    get new_change_request_path
    response.headers['Content-Security-Policy'].split(';').to_h do |part|
      name, *sources = part.split
      [name, sources]
    end
  end

  it 'lets the widget load its script and its frame from Cloudflare' do
    directives = policy
    expect(response.body).to include('cf-turnstile')
    expect(directives['script-src']).to include("'strict-dynamic'")
    expect(directives['script-src'].grep(/\A'nonce-/)).not_to be_empty

    frames = directives['frame-src'] || directives['child-src'] ||
             directives['default-src']
    expect(frames & ['https:', 'https://challenges.cloudflare.com']).
      not_to be_empty
  end

  it 'limits base URLs and form submissions to this site' do
    directives = policy
    expect(directives['base-uri']).to eq(["'self'"])
    expect(directives['form-action']).to eq(["'self'"])
  end
end
