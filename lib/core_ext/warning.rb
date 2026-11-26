# Lets a block turn Ruby's warnings into errors it can rescue.
module Warning
  class RaisedWarning < StandardError; end

  def self.with_raised_warnings
    alias_method :warn_original, :warn
    alias_method :warn, :raise_warning
    yield if block_given?
  ensure
    alias_method :warn, :warn_original
  end

  def raise_warning(msg)
    raise RaisedWarning, msg
  end
end
