# Scores accounts for spam at sign-up, sign-in and email change using
# thresholds and lists configurable via config/user_spam_scorer.yml.
class UserSpamScorer
  def self.for_accounts
    new
  end

  DEFAULT_SCORE_MAPPINGS = {
    name_is_all_lowercase?: 1,
    name_is_one_word?: 1,
    name_includes_non_alpha_characters?: 1,
    name_is_garbled?: 1,
    email_from_suspicious_domain?: 10,
    email_from_spam_domain?: 13,
    email_from_spam_tld?: 1,
    email_is_spam_format?: 3,
    name_is_spam_format?: 10,
    user_agent_is_suspicious?: 3,
    ip_range_is_suspicious?: 12
  }.freeze

  DEFAULT_SUSPICIOUS_DOMAINS =
    %w(mail.ru
       temp-mail.de
       tempmail.de
       shitmail.de
       yopmail.com
       yandex.com).freeze
  DEFAULT_SPAM_DOMAINS =
    %w(163.com
       7x.cz
       allemaling.com
       brmailing.com
       businessmailsystem.com
       checknowmail.com
       colde-mail.com
       consimail.com
       continumail.com
       contumail.com
       customprintingfabric.com
       cyclingitems.com
       elong-led.com
       emailber.com
       fulldesigns.net
       grow-mail.com
       inemaling.com
       inmailing.com
       itemailing.com
       itmailing.com
       juchanghn.com
       kod-emailing.com
       kod-maling.com
       kodemailing.com
       kodmailing.com
       left-mail.com
       mabermail.com
       mailphar.com
       msqmakeupbrush.com
       out-email.com
       semi-mile.com
       showerspasystem.com
       sin-mailing.com
       sinemailing.com
       sinmailing.com
       takmailing.com
       themailemail.com
       visitinbox.com
       webgarden.com
       webgarden.cz
       wgz.cz
       wowmailing.com).freeze
  DEFAULT_SPAM_EMAIL_FORMATS = [].freeze
  DEFAULT_SPAM_NAME_FORMATS = [
    /\A.*bitcoin.*\z/i,
    /\A.*currency.*\z/i,
    /\A.*support.*\z/i,
    /\A.*customer.*service.*\z/i,
    /\A.*customer.*care.*\z/i,
    /\A.*buy.*online.*\z/i,
    /\A.*real.*estate.*\z/i,
    /\A.*web.*design.*\z/i,
    /\A.*Mac\sDesktop.*\z/i,
    /\A.*Inc\z/,
    /\A.*LLC\z/,
    /\A.*spyware.*\z/i,
    /\A.*malware.*\z/i,
    /\A.*CRM.*\z/
  ].freeze
  DEFAULT_SPAM_SCORE_THRESHOLD = 12
  DEFAULT_SPAM_TLDS = %w(ru pl).freeze
  DEFAULT_SUSPICIOUS_USER_AGENTS = [].freeze
  DEFAULT_SUSPICIOUS_IP_RANGES = [].freeze

  CLASS_ATTRIBUTES = [:score_mappings,
                      :suspicious_domains,
                      :spam_domains,
                      :spam_email_formats,
                      :spam_name_formats,
                      :spam_score_threshold,
                      :spam_tlds,
                      :suspicious_user_agents,
                      :suspicious_ip_ranges].freeze

  # Legacy config keys ignored for compatibility.
  RETIRED_SETTINGS = %w[currency_symbols spam_about_me_formats].freeze

  # Custom scoring methods registry
  @custom_scoring_methods = {}

  def self.custom_scoring_methods
    @custom_scoring_methods ||= {}
  end

  # Class attribute accessors
  CLASS_ATTRIBUTES.each do |key|
    define_singleton_method "#{ key }=" do |value|
      instance_variable_set("@#{ key }", value)
    end

    define_singleton_method key do
      value = instance_variable_get("@#{ key }") ||
              const_get("DEFAULT_#{ key }".upcase)
      instance_variable_set("@#{ key }", value)
    end
  end

  def self.configure(settings)
    settings.except(*RETIRED_SETTINGS).each do |key, value|
      public_send("#{key}=", value)
    end
  end

  def self.reset
    CLASS_ATTRIBUTES.each do |key|
      instance_variable_set("@#{ key }", const_get("DEFAULT_#{ key }".upcase))
    end

    old_methods = custom_scoring_methods.keys
    custom_scoring_methods.clear

    CLASS_ATTRIBUTES + old_methods
  end

  def self.register_custom_scoring_method(method_name, score_value, method_proc)
    custom_scoring_methods[method_name] = {
      score: score_value,
      proc: method_proc
    }
  end

  # Instance attribute accessors
  CLASS_ATTRIBUTES.each do |key|
    attr_reader key
  end

  def initialize(opts = {})
    CLASS_ATTRIBUTES.each do |key|
      instance_variable_set("@#{ key }", opts.fetch(key, self.class.send(key)))
    end

    @score_mappings ||= []
    self.class.custom_scoring_methods.each do |method_name, config|
      @score_mappings = @score_mappings.merge(method_name => config[:score])
    end
  end

  def spam?(user)
    score(user) > spam_score_threshold
  end

  def score(user)
    score_mappings.inject(0) do |score_count, score_mapping|
      method_name = score_mapping.first
      score_value = score_mapping.last

      result = if self.class.custom_scoring_methods.key?(method_name)
                 config = self.class.custom_scoring_methods[method_name]
                 config[:proc].call(user)
               else
                 send(method_name, user)
               end

      if result
        score_count + score_value
      else
        score_count
      end
    end
  end

  def name_is_all_lowercase?(user)
    user.name == user.name.downcase
  end

  def name_is_one_word?(user)
    !(user.name =~ /\s/)
  end

  def name_includes_non_alpha_characters?(user)
    !(user.name.strip =~ /\A[a-zA-Z\s]+\z/i)
  end

  # Five letters in a row with no a, e, i, o or u among them.
  def name_is_garbled?(user)
    /[[:alpha:]&&[^aeiouAEIOU]]{5,}/.match?(user.name)
  end

  def email_from_suspicious_domain?(user)
    suspicious_domains.include?(user.email_domain)
  end

  def email_from_spam_domain?(user)
    spam_domains.include?(user.email_domain)
  end

  def email_from_spam_tld?(user)
    domain = user.email_domain
    return false if domain.blank?

    spam_tlds.any?(domain.split('.').last)
  end

  def email_is_spam_format?(user)
    spam_email_formats.any? { |regexp| user.email =~ regexp }
  end

  def name_is_spam_format?(user)
    spam_name_formats.any? { |regexp| user.name.strip =~ regexp }
  end

  def user_agent_is_suspicious?(user)
    return false unless user.respond_to?(:user_agent)

    suspicious_user_agents.include?(user.user_agent)
  end

  def ip_range_is_suspicious?(user)
    return false unless user.respond_to?(:ip)

    suspicious_ip_ranges.any? { |range| IPAddr.new(range).include?(user.ip) }
  end

  # TODO: Akismet thinks user is spam
  # TODO: User has no transactions
end
