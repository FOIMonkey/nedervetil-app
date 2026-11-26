# Joins and splits fixed greeting/sign-off lines around the editable middle of
# an initial FOI request body.
module RequestLetter
  module_function

  def template
    OutgoingMessage::Template::InitialRequest.new
  end

  def greeting(body_name)
    template.salutation(public_body_name: body_name)
  end

  # Unescape gettext's HTML-escaped salutation for plain-text letters.
  def greeting_text(body_name)
    CGI.unescapeHTML(greeting(body_name).to_str)
  end

  def join(middle, body_name, user_name)
    text(greeting(body_name), middle, template.signoff, user_name)
  end

  def text(greeting, middle, signoff, user_name)
    "#{CGI.unescapeHTML(greeting.to_str)}\n\n" \
      "#{middle.to_s.gsub("\r\n", "\n").strip}\n\n#{signoff}\n\n#{user_name}"
  end

  # Returns middle text or nil; accepts legacy HTML-escaped greetings.
  def split(body, body_name, user_name)
    text = body.to_s.gsub("\r\n", "\n").strip
    greetings = [greeting_text(body_name), greeting(body_name).to_str].uniq.
      map { |line| Regexp.escape(line) }
    # rubocop:disable Layout/LineLength
    pattern = /\A(?:#{greetings.join('|')})\s*(.*?)\s*#{Regexp.escape(template.signoff)}\s*#{Regexp.escape(user_name.to_s)}\z/m
    # rubocop:enable Layout/LineLength
    text[pattern, 1]
  end

  def subject(question)
    line = question.to_s.strip.lines.first.to_s.squish.sub(/[?.!\s]+\z/, '')
    line = "#{line.first(80).sub(/\s+\S*\z/, '')}…" if line.length > 80
    line.sub(/\A[a-z]/, &:upcase)
  end
end
