# Refuses to boot outside development/test unless SANDBOX_CONVERTERS is
# required, so a missing or mistyped setting cannot silently fall back to
# unsandboxed conversion (core's default). Checks config only so a temporary
# sandbox outage does not block boot; AlaveteliSandbox still fails closed
# per step.
module ConverterSandboxCheck
  module_function

  def verify!(env: Rails.env, mode: AlaveteliSandbox.mode)
    return if env.to_s.in?(%w[development test])
    return if mode == :required

    raise AlaveteliSandbox::ConfigurationError,
          'This site requires SANDBOX_CONVERTERS: required in ' \
          "config/general.yml (the effective mode is #{mode}). Document " \
          'converters must not run unsandboxed.'
  end
end
