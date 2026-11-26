require 'spec_helper'

RSpec.describe 'Turbo script guard', js: true do
  it 'inserts a stream update without running its injected script' do
    visit help_about_path
    page.execute_script(<<~JS)
      const target = document.createElement('div')
      target.id = 'security-stream-target'
      document.body.appendChild(target)
      Turbo.renderStreamMessage(`
        <turbo-stream action="append" target="security-stream-target">
          <template>
            <script>window.injectedStreamScriptRan = true</script>
            <span id="security-stream-content">Stream content</span>
          </template>
        </turbo-stream>`)
    JS

    expect(page).to have_css('#security-stream-content', text: 'Stream content')
    expect(page.evaluate_script('window.injectedStreamScriptRan')).to be_nil
  end

  it 'renders a frame without running its injected script' do
    allow_any_instance_of(HelpController).to receive(:contact) do |controller|
      controller.render layout: false, html: <<~HTML.html_safe
        <turbo-frame id="security-frame">
          <script>window.injectedFrameScriptRan = true</script>
          <span id="security-frame-content">Frame content</span>
        </turbo-frame>
      HTML
    end

    visit help_about_path
    page.execute_script(<<~JS)
      const frame = document.createElement('turbo-frame')
      frame.id = 'security-frame'
      frame.src = '#{help_contact_path}'
      document.body.appendChild(frame)
    JS

    expect(page).to have_css('#security-frame-content', text: 'Frame content')
    expect(page.evaluate_script('window.injectedFrameScriptRan')).to be_nil
  end
end
