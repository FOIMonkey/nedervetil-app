# Request limits are on in a run with REQUEST_LIMITS=on and off otherwise.
RSpec.shared_context 'with request limits on' do
  around do |example|
    with_setting(RequestLimits, :enforced, true) { example.run }
  end
end

RSpec.shared_context 'with request limits off' do
  around do |example|
    with_setting(RequestLimits, :enforced, false) { example.run }
  end
end

RSpec.shared_context 'with request limits on, on the real clock' do
  include_context 'with request limits on'

  after { travel_back }

  def without_limits(&block)
    with_setting(RequestLimits, :enforced, false, &block)
  end
end
