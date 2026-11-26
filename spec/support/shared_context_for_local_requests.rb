# Rails copies consider_all_requests_local into env_config's
# show_detailed_exceptions the first time env_config is read, and keeps that
# copy. If the first read happens while an example has stubbed the setting
# (see 'with production error pages'), every later request in the process
# gets the stubbed value. So these contexts set the copy Rails reads as well.
RSpec.shared_context 'consider all requests local', local_requests: true do
  include_context 'show exceptions'

  around do |example|
    with_requests_local(true) { example.run }
  end
end

RSpec.shared_context 'consider all requests remote', local_requests: false do
  include_context 'show exceptions'

  around do |example|
    with_requests_local(false) { example.run }
  end
end

def with_requests_local(local)
  config = Rails.application.config
  env_config = Rails.application.env_config
  saved = [config.consider_all_requests_local,
           env_config['action_dispatch.show_detailed_exceptions']]
  begin
    config.consider_all_requests_local = local
    env_config['action_dispatch.show_detailed_exceptions'] = local
    yield
  ensure
    config.consider_all_requests_local,
      env_config['action_dispatch.show_detailed_exceptions'] = saved
  end
end
