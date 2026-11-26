class MockPOP3
  # Shared by every instance, as one mailbox on a server would be.
  class << self
    attr_accessor :started, :mail_list
  end

  self.started = false

  def initialize(number_of_mails = 20)
    self.class.mail_list = []
    number_of_mails.times do |i|
      # "test00", "test01", "test02", ..., "test19"
      self.class.mail_list << MockPopMail.new("test#{i.to_s.rjust(2, '0')}", i)
    end
  end

  def self.popmails
    mail_list.clone
  end

  def self.started?
    started == true
  end

  def each_mail(*_args, &block)
    self.class.mail_list.each(&block)
  end

  def mails(*_args)
    self.class.mail_list.clone
  end

  def start(*_args)
    self.class.started = true
    block_given? ? yield(self) : self
  end

  # Stands in for Net::POP3#enable_ssl, whose result the poller ignores.
  def enable_ssl(*_args)
  end

  def started?
    self.class.started?
  end

  def reset
  end

  def finish
    self.class.started = false
  end

  def delete_all
    self.class.mail_list = []
  end
end
