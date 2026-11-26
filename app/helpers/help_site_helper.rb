# For the help_site views, which show a theme's help pack (lib/help_site.rb).
module HelpSiteHelper
  def help_content = HelpSite.content

  # A pictogram from the pack's signs.yml, or core's.
  def help_sign(name, extra = nil)
    return unless name

    tag.svg(help_content.signs.fetch(name).html_safe, # rubocop:disable Rails/OutputSafety
            class: ['help-sign', extra], viewBox: '0 0 48 48',
            aria: { hidden: true }, focusable: false)
  end

  # An answer's text. The pack is the theme's own files, so its Markdown may
  # hold HTML.
  def help_markdown(source)
    HelpSite::Markdown.render(source, help_content).html_safe # rubocop:disable Rails/OutputSafety
  end

  def help_word_id(word) = HelpSite::Markdown.word_id(word)

  # A word listed in lower case starts with a capital; any other keeps the
  # capitals it was listed with.
  def help_word_title(word) = word == word.downcase ? word.capitalize : word

  # A help page's title is in the page band, with the section's sign beside
  # it, so the page is a band view and its notice goes straight after the
  # band (ApplicationHelper#band_notice). Call this after the band.
  def help_after_band
    content_for :body_class, ' band-view '
    band_notice
  end

  # An answer's `extra` names a partial in help_site/extras, which the theme
  # provides.
  def help_extra(answer)
    return unless answer.extra

    name = answer.extra.tr('-', '_')
    raise ArgumentError, "Bad extra: #{name}" unless name.match?(/\A[a-z_]+\z/)

    render "help_site/extras/#{name}", answer: answer
  end
end
