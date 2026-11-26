# Loaded by handle-mail-replies spec to intercept /usr/sbin/sendmail via a real
# pipe to `cat` (sendmail is absent or stalls ~60s without a local MTA).
require 'json'
require 'shellwords'

module StubSendmail
  def popen(cmd, *args, **opts, &block)
    return super unless cmd.is_a?(Array) && cmd.first == '/usr/sbin/sendmail'

    out = ENV.fetch('STUB_SENDMAIL_OUT')
    File.write("#{out}.cmd", JSON.generate(cmd))
    super("cat > #{Shellwords.escape(out)}", *args, **opts, &block)
  end
end

IO.singleton_class.prepend(StubSendmail)
