require 'spec_helper'

RSpec.describe 'admin/users/_post_redirects' do
  it 'does not read or display any legacy token, path or saved parameter' do
    rows = double('legacy rows')
    expect(rows).not_to receive(:each)
    render partial: 'admin/users/post_redirects',
           locals: { post_redirects: rows }
    expect(rendered).to include('Legacy authentication links are retired')
    expect(rendered).not_to include('href=', 'form', 'token')
  end
end
