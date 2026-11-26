require 'ripper'

module CopyRules
  # Reads literal copy from ERB without evaluating the template.
  class Template
    TRANSLATIONS = {
      '_' => [0], 'N_' => [0], 's_' => [0],
      'n_' => [0, 1], 'Nn_' => [0, 1], 'ns_' => [0, 1],
      'p_' => [1], 'np_' => [1, 2]
    }.freeze

    def initialize(source)
      @source = source.gsub(/<%#.*?%>/m, ' ').
        gsub(%r{<script.*?</script>}m, ' ').
        gsub(%r{<style.*?</style>}m, ' ').gsub(/<!--.*?-->/m, ' ')
      ruby = @source.scan(/<%[=-]?(.*?)-?%>/m).flatten.join("\n")
      tree = Ripper.sexp("def render_copy;\n#{ruby}\nend")
      raise ArgumentError, 'Cannot parse template copy' unless tree

      @calls = calls(tree)
    end

    def text
      plain = @source.gsub(/<%.*?%>/m, ' ')
      translated = @calls.flat_map { |name, args| translations(name, args) }
      ([plain] + translated).join(' ').gsub(/<[^>]+>/m, ' ')
    end

    def labels(*methods)
      @calls.select { |name, _| methods.include?(name) }.
        flat_map { |_, args| strings(args.first) }
    end

    private

    def calls(node)
      return [] unless node.is_a?(Array)

      current = case node.first
                when :command
                  [node[1][1], arguments(node[2])]
                when :command_call
                  [node[3][1], arguments(node[4])]
                when :method_add_arg
                  method = node[1]
                  name = method.first == :call ? method[3][1] : method[1][1]
                  [name, arguments(node[2])]
                end
      [current].compact + node.grep(Array).flat_map { |child| calls(child) }
    end

    def arguments(node)
      return [] unless node
      return arguments(node[1]) if node.first == :arg_paren

      node.first == :args_add_block ? node[1] : []
    end

    def strings(node)
      return [] unless node.is_a?(Array)

      if [:string_literal, :string_concat].include?(node.first)
        [content(node)]
      else
        call = calls(node).find { |name, _| TRANSLATIONS.key?(name) }
        call ? translations(*call) : []
      end
    end

    def content(node)
      return node[1] if node.first == :@tstring_content
      return '{{value}}' if node.first == :string_embexpr

      node.grep(Array).map { |child| content(child) }.join
    end

    def translations(name, args)
      return [] unless TRANSLATIONS.key?(name)

      TRANSLATIONS.fetch(name).flat_map { |index| strings(args[index]) }.
        map do |text|
          %w[s_ ns_].include?(name) ? text.split('|', 2).last : text
        end
    end
  end
end
