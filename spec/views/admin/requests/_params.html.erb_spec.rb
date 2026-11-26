require 'spec_helper'

RSpec.describe 'when showing diffs in info_request params' do
  def do_render(params)
    render partial: 'admin/requests/params', locals: { params: params }
  end

  it 'should differentiate between old, new and other' do
    ire = InfoRequestEvent.new
    ire.params = { old_foo: 'this is stuff', foo: 'stuff', bar: 84 }
    do_render(ire.params_diff)
    expect(response.body.squish).to match(
      "<em>foo:</em> this is stuff => stuff <br> <em>bar:</em> 84 <br>"
    )
  end

  it "should convert linebreaks to '<br>'s" do
    ire = InfoRequestEvent.new
    ire.params = { old_foo: "this\nis\nstuff", foo: "this\nstuff", bar: 84 }
    do_render(ire.params_diff)
    expect(response.body.squish).to match(
      "<em>foo:</em> this<br> is<br> stuff => this<br> stuff <br> " \
      "<em>bar:</em> 84 <br>"
    )
  end

  it 'escapes markup in a value before adding the linebreaks' do
    ire = InfoRequestEvent.new
    ire.params = { old_foo: "<b>old</b>\nline", foo: '<script>new</script>' }
    do_render(ire.params_diff)
    expect(response.body).to include('&lt;b&gt;old&lt;/b&gt;<br>')
    expect(response.body).to include('&lt;script&gt;new&lt;/script&gt;')
    expect(response.body).not_to include('<b>', '<script>')
  end

  it 'should not report unchanged values as new' do
    ire = InfoRequestEvent.new
    ire.params = { old_foo: 'this is stuff', foo: 'this is stuff', bar: 84 }
    do_render(ire.params_diff)
    expect(response.body.squish).to match("<em>bar:</em> 84 <br>")
  end
end
