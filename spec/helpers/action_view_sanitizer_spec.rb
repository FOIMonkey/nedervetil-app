require 'spec_helper'

RSpec.describe 'HTML sanitizer tag policy' do
  it 'does not preserve injected style or document container tags' do
    html = '<html><head><style>body{display:none}</style></head>' \
           '<body><table><tr><td>safe</td></tr></table></body></html>'
    sanitized = ActionController::Base.helpers.sanitize(html)
    expect(sanitized).not_to include('<style>', '<head>', '<body>', '<html>')
    expect(sanitized).to include('<table>', 'safe')
  end
end
