# Set BROWSER_PATH if Cuprite cannot find Chrome or Chromium automatically.
require 'capybara/cuprite'

# Rails' driven_by registers the driver itself, so the options go there.
CUPRITE_OPTIONS = {
  js_errors: true,
  # Keep Cloudflare Turnstile unloaded so specs only see widget markup.
  url_blacklist: ['https://challenges.cloudflare.com/*'],
  process_timeout: 60,
  # A page's first visit can wait on a cold asset compile.
  timeout: 30,
  # Container runs as root (no sandbox) with a small /dev/shm.
  browser_options: if ENV['DOCKER']
                     { 'no-sandbox' => nil, 'disable-dev-shm-usage' => nil }
                   else
                     {}
                   end
}.freeze

Capybara.javascript_driver = :cuprite
Capybara.server = :puma, { Silent: true }

module JavascriptHelpers
  # A first visit can wait on a cold asset compile.
  NAVIGATION_WAIT = 15

  NAVIGATION_KINDS = {
    turbo: 'Turbo Drive rendered it',
    full: 'the page loaded in full',
    none: 'the page stayed as it was'
  }.freeze

  def eventually(wait: Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    loop do
      return true if yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def expect_turbo_visit(&)
    kind = navigation_kind(&)
    expect(kind).to eq(:turbo),
      "expected Turbo Drive to render the page, but #{NAVIGATION_KINDS[kind]}"
  end

  def expect_full_load(&)
    kind = navigation_kind(&)
    expect(kind).to eq(:full),
      "expected a full page load, but #{NAVIGATION_KINDS[kind]}"
  end

  # Full load with no prior Turbo visit (opt-out pages still fire turbo:visit
  # before reloading, so sessionStorage records whether Turbo intervened).
  def expect_left_to_browser(&)
    page.execute_script(<<~JS)
      sessionStorage.removeItem('turboSpecVisited');
      document.addEventListener('turbo:visit', () => {
        sessionStorage.setItem('turboSpecVisited', '1');
      });
    JS
    expect_full_load(&)
    expect(page.evaluate_script("sessionStorage.getItem('turboSpecVisited')")).
      to be_nil, 'expected no Turbo visit, but Turbo visited first'
  end

  def go_back_with_turbo
    restore_with_turbo('Back') { page.go_back }
  end

  def go_forward_with_turbo
    restore_with_turbo('Forward') { page.go_forward }
  end

  private

  def restore_with_turbo(button)
    page.execute_script(<<~JS)
      window.turboSpecRestore = null;
      document.addEventListener('turbo:visit', (event) => {
        window.turboSpecRestore = event.detail.action;
      }, { once: true });
      document.addEventListener('turbo:load', () => {
        if (window.turboSpecRestore) window.turboSpecRestore += ':loaded';
      }, { once: true });
    JS
    yield
    restored = eventually(wait: NAVIGATION_WAIT) do
      page_value('window.turboSpecRestore') == 'restore:loaded'
    end
    expect(restored).to be(true),
      "expected #{button} to be a Turbo restoration visit"
  end

  def navigation_kind
    # window.turboSpecMarker survives a Turbo visit and disappears on a full
    # load. turbo:load fires after redirects; failed forms only turbo:render.
    page.execute_script(<<~JS)
      window.turboSpecMarker = true;
      window.turboSpecVisited = false;
      window.turboSpecRendered = false;
      document.addEventListener('turbo:visit', () => {
        window.turboSpecVisited = true;
      });
      document.addEventListener('turbo:load', () => {
        window.turboSpecRendered = true;
      });
      document.addEventListener('turbo:render', () => {
        if (!window.turboSpecVisited) window.turboSpecRendered = true;
      });
    JS
    yield
    kind = nil
    eventually(wait: NAVIGATION_WAIT) do
      state = page_value(
        '[window.turboSpecMarker === true, ' \
        'window.turboSpecRendered === true, document.readyState]'
      )
      kind = case state
             in [true, true, _] then :turbo
             in [false, _, 'complete'] then :full
             else nil
             end
    end
    kind || :none
  end

  # A value from the page, or nil while it is between documents.
  def page_value(script)
    page.evaluate_script(script)
  rescue Ferrum::NoExecutionContextError, Ferrum::NodeNotFoundError
    nil
  end
end

RSpec.configure do |config|
  config.include JavascriptHelpers, type: :system

  config.before(:each, type: :system) do |example|
    if example.metadata[:js]
      # Allow Capybara's local server check and Cuprite's Chromium connection.
      WebMock.disable_net_connect!(allow_localhost: true)
      driven_by :cuprite, screen_size: [1280, 900],
                          options: CUPRITE_OPTIONS.deep_dup
    else
      driven_by :rack_test
    end
  end

  config.after(:each, type: :system, js: true) do
    WebMock.disable_net_connect!

    # Named sessions (from login) each spawn Chromium and are only reset,
    # not quit, between examples.
    Capybara.send(:session_pool).delete_if do |key, session|
      next false if key.split(':')[1] == 'default'

      session.driver.quit if session.driver.respond_to?(:quit)
      true
    end
  end
end
