require 'cgi'
require 'yaml'
require 'redcarpet'

# The help pages at /help, built from a theme's help pack: a folder of Markdown
# answers and YAML (doc/FORK.md describes it). This reads the pack;
# HelpSiteController and the help_site views show it. With no pack there are
# no pages, and /help lists the older help pages instead.
module HelpSite
  DEFAULTS = File.expand_path('help_site', __dir__)

  Section = Struct.new(:slug, :title, :description, :sign, :answers, :glance,
                       :glance_title, :group, keyword_init: true) do
    def path = "/help/#{slug}"
  end

  Answer = Struct.new(:id, :section, :question, :short, :related, :extra,
                      :markdown, keyword_init: true) do
    def path = "#{section.path}/#{id}"
  end

  # A page of the pack: its address, and the help_site view that shows it.
  Page = Struct.new(:path, :title, :view, :section, :answer, keyword_init: true)

  # One pack's answers and words, read from its folder.
  class Content
    attr_reader :root, :groups, :sections, :answers, :glossary, :reasons,
                :guide, :signs

    def initialize(root = nil)
      @root = root
      @glossary = load_yaml('glossary.yml') || {}
      @reasons = load_yaml('refusal_reasons.yml') || []
      @guide = load_yaml('guide.yml')
      @signs = HelpSite.signs_in(root)
      @answers = {}
      rows = (load_yaml('sections.yml') || {}).fetch('groups', [])
      @groups = rows.map do |group|
        { title: group['title'],
          sections: group['sections'].map { section_from(_1, group['title']) } }
      end
      @sections = @groups.flat_map { _1[:sections] }
    end

    def pack? = !root.nil?

    def section(slug) = sections.find { _1.slug == slug }

    def pages
      return [] unless pack?

      [home, *sections.map { section_page(_1) },
       *answers.values.map { answer_page(_1) }, words, guide_page].compact
    end

    def page(path) = pages.find { _1.path == path }

    def answer_at(section_and_id)
      answers.values.find { _1.path == "/help/#{section_and_id}" }
    end

    # A word's explanation, however the answer capitalises it.
    def meaning(word)
      glossary.find { |key, _| key.downcase == word.downcase }&.last
    end

    def search_index
      answers.values.map do |answer|
        { url: answer.path, question: answer.question, short: answer.short,
          section: answer.section.title, text: search_text(answer.markdown) }
      end
    end

    private

    def read(name)
      path = root && File.join(root, name)
      File.read(path) if path && File.exist?(path)
    end

    def load_yaml(name)
      source = read(name)
      YAML.safe_load(source) if source
    end

    # What a reader sees: no notes still to be written, link addresses or
    # [[shown|word]] targets.
    def search_text(markdown)
      markdown.gsub(/^> .*$/, '').gsub(/\]\([^)]*\)/, ' ').
        gsub(/\|[^\]]+\]\]/, ' ').gsub(/[\[\]*#]/, ' ').squeeze(" \n").strip
    end

    def section_from(row, group)
      section = Section.new(slug: row['slug'], title: row['title'],
                            description: row['description'], sign: row['sign'],
                            glance: row['glance'],
                            glance_title: row['glance_title'], group: group)
      section.answers = row['answers'].map { answer_from(_1, section) }
      section
    end

    def answer_from(id, section)
      source = read(File.join('answers', section.slug, "#{id}.md")) ||
               raise(Errno::ENOENT, "answers/#{section.slug}/#{id}.md")
      # Related answers and search name an answer by its ID alone.
      raise ArgumentError, "The answer ID #{id} is used twice" if
        @answers.key?(id)

      _, front, markdown = source.split(/^---\s*$/, 3)
      data = YAML.safe_load(front)
      @answers[id] = Answer.new(
        id: id, section: section, question: data['question'],
        short: data['short'], related: data['related'] || [],
        extra: data['extra'], markdown: markdown.strip
      )
    end

    def home = Page.new(path: '/help', view: 'home')

    def section_page(section)
      Page.new(path: section.path, title: section.title, view: 'section',
               section: section)
    end

    def answer_page(answer)
      Page.new(path: answer.path, title: answer.question, view: 'answer',
               section: answer.section, answer: answer)
    end

    def words
      Page.new(path: '/help/words', view: 'words') unless glossary.empty?
    end

    # The one-page guide is the theme's own: the pack's guide.yml, shown by
    # the theme's help_site/guide view.
    def guide_page
      Page.new(path: '/help/guide', title: guide['title'], view: 'guide') if
        guide
    end
  end

  # Matches the addresses of the pack's pages, and anything under one of its
  # sections, so every other /help address goes on to the older help pages.
  class PageConstraint
    def self.matches?(request)
      HelpSite.reload_in_development!
      content = HelpSite.content
      parts = request.path_parameters.values_at(:section, :answer).compact
      !(content.section(parts.first) ||
        content.page(['/help', *parts].join('/'))).nil?
    end
  end

  # The pack's folder. The theme loader lists each theme's lib/help_site; the
  # first theme in THEME_URLS with a sections.yml there provides the pack.
  def self.root
    return @root if defined?(@root)
    return unless defined?(Rails)

    @found ||= [Rails.configuration.paths['help_site'].existent.reverse.find do
      File.exist?(File.join(_1, 'sections.yml'))
    end]
    @found.first
  end

  # Whether a theme has a pack, without reading it: a mistake in a pack
  # breaks its own pages, not the menu on every other page.
  def self.pack? = !root.nil?

  # Names the folder outright, for a spec. Use `reset_root!` to go back to
  # the loaded themes' pack.
  def self.root=(path)
    @root = path
    reload!
  end

  def self.reset_root!
    remove_instance_variable(:@root) if defined?(@root)
    reload!
  end

  def self.content = (@content ||= Content.new(root))

  # Core's pictograms and the pack's, read without the rest of the pack, for
  # a view elsewhere on the site that draws one.
  def self.signs = (@signs ||= signs_in(root))

  def self.signs_in(root)
    own = root && File.join(root, 'signs.yml')
    signs = YAML.safe_load_file(File.join(DEFAULTS, 'signs.yml'))
    own && File.exist?(own) ? signs.merge(YAML.safe_load_file(own)) : signs
  end

  def self.reload!
    @found = nil
    @content = nil
    @signs = nil
  end

  # In development the pack is read again for each help request, so an edit
  # shows without a restart.
  def self.reload_in_development!
    reload! if defined?(Rails) && Rails.env.development?
  end

  # Turns an answer's Markdown into HTML. A link out of the site is marked,
  # and a quote is a note still to be written.
  class Markdown < Redcarpet::Render::HTML
    # [[word]] or [[shown|word]] in an answer.
    WORD = /\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/

    def initialize
      super({})
    end

    def link(url, _title, text)
      out = ' class="help-out"' if url.start_with?('http')
      %(<a href="#{CGI.escapeHTML(url)}"#{out}>#{text}</a>)
    end

    def block_quote(quote) = %(<div class="help-todo">#{quote}</div>\n)

    # Each marked word is a link to its explanation on the words page, which
    # the help-words controller opens in place.
    def self.render(source, content)
      with_words = source.gsub(WORD) do
        shown = Regexp.last_match(1)
        word = Regexp.last_match(2) || shown
        means = content.meaning(word) ||
                raise(KeyError, "No such word: #{word}")
        %(<a class="help-word" href="/help/words##{word_id(word)}" ) +
          %(data-means="#{CGI.escapeHTML(means)}">#{shown}</a>)
      end
      Redcarpet::Markdown.new(new, no_intra_emphasis: true, lax_spacing: true).
        render(with_words)
    end

    # Letters and digits of any script, so two words never share an anchor
    # because neither is written in Latin letters.
    def self.word_id(word) = word.downcase.gsub(/[^\p{L}\p{N}]+/, '-')
  end
end
