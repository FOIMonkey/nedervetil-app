module SettingsHelpers
  def with_setting(receiver, name, value)
    previous = stored_setting(receiver, name)
    receiver.public_send("#{name}=", value)
    yield
  ensure
    receiver.public_send("#{name}=", previous)
  end

  def keeping_settings(receiver, *names)
    previous = names.to_h { |name| [name, stored_setting(receiver, name)] }
    yield
  ensure
    previous.each { |name, value| receiver.public_send("#{name}=", value) }
  end

  private

  # The value set, not a reader's fallback to the configuration, so putting it
  # back leaves the fallback working.
  def stored_setting(receiver, name)
    variable = :"@@#{name}"
    unless receiver.class_variable_defined?(variable)
      return receiver.public_send(name)
    end

    receiver.class_variable_get(variable)
  end
end

RSpec.configure do |config|
  config.include SettingsHelpers
end
