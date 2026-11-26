module AlaveteliSandbox
  # Enforces imagemagick-policy.xml (no delegates/filters, restricted coders
  # and paths) against `magick -list policy` inside the sandbox. The PDF cell
  # checks this at startup and refuses to serve if /etc/ImageMagick-7 differs.
  # See doc/FORK.md.
  module ImagePolicy
    PROGRAM = 'magick'.freeze
    FILE = File.expand_path('imagemagick-policy.xml', __dir__)

    # What must be exactly as FILE has it, whatever file it was read from:
    # every domain that says what ImageMagick may do. The resource limits may
    # differ from one machine to another.
    DOMAINS = %w[delegate filter path module coder].freeze

    module_function

    # FILE's entries for DOMAINS, each as [domain, rights, pattern].
    def required
      policies = File.read(FILE).gsub(/<!--.*?-->/m, '').scan(/<policy\s[^>]*>/)
      entries(policies.map { |policy| policy.scan(/(\w+)="([^"]*)"/).to_h })
    end

    # The entries for DOMAINS in the output of `magick -list policy`, which
    # lists what ImageMagick loaded from every policy file it found.
    def listed(listing)
      policies = []
      listing.each_line do |line|
        key, value = line.strip.split(': ', 2)
        case key
        when 'Policy' then policies << { 'domain' => value }
        when 'rights', 'pattern' then policies.last&.store(key, value)
        end
      end
      entries(policies)
    end

    def entries(policies)
      policies.filter_map do |policy|
        domain = policy['domain'].to_s.downcase
        next unless DOMAINS.include?(domain)

        [domain, rights(policy['rights']), policy['pattern'].to_s.strip]
      end
    end

    # Rights as a sorted list: "read|write" in a policy file, "Read Write" in
    # a listing.
    def rights(text)
      text.to_s.downcase.split(/[|\s]+/).reject(&:empty?).sort
    end

    # nil when the policy in force, as listed, has exactly FILE's entries for
    # DOMAINS. Otherwise, how it differs.
    def problem(listing)
      in_force = listed(listing)
      missing = required - in_force
      added = in_force - required
      return if missing.empty? && added.empty?

      differences = { 'without' => missing, 'with' => added }.
                    reject { |_, entries| entries.empty? }.
                    map { |word, entries| "#{word} #{describe(entries)}" }
      "ImageMagick's policy in force is not imagemagick-policy.xml: it is " \
        "#{differences.join(', and ')}"
    end

    def describe(entries)
      entries.map do |domain, rights, pattern|
        "#{domain} #{rights.join('|')} #{pattern}".strip
      end.join('; ')
    end
  end
end
