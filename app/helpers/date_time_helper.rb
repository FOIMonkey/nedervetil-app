# Formats dates and times for HTML <time> tags, plain text and ISO date inputs.
module DateTimeHelper
  # Formats a date filter for <input type="date"> (YYYY-MM-DD), accepting
  # legacy slash-separated URL dates (DD/MM/YYYY, YYYY/MM/DD).
  def date_field_value(value)
    text = value.to_s.strip
    date =
      case text
      when /\A\d{4}-\d{2}-\d{2}\z/ then Date.iso8601(text)
      when %r{\A\d{4}/\d{1,2}/\d{1,2}\z} then Date.strptime(text, '%Y/%m/%d')
      when %r{\A\d{1,2}/\d{1,2}/\d{4}\z} then Date.strptime(text, '%d/%m/%Y')
      end
    date&.iso8601
  rescue Date::Error
    nil
  end

  # Public: Usually-correct format for a DateTime-ish object
  # To define a new new format define the `simple_date_{FORMAT}` method
  #
  # date - a DateTime, Date or Time
  # opts - a Hash of options (default: { format: :html})
  #        :format - :html returns a HTML <time> tag
  #                  :text returns a plain String
  #
  # Examples
  #
  #   simple_date(Time.now)
  #   # => "<time>..."
  #
  #   simple_date(Time.now, :format => :text)
  #   # => "March 10, 2014"
  #
  # Returns a String
  # Raises ArgumentError if the format is unrecognized
  def simple_date(date, opts = {})
    opts = { format: :html }.merge(opts)
    date_formatter = "simple_date_#{ opts[:format] }"

    unless respond_to?(date_formatter)
      raise ArgumentError, "Unrecognized format :#{ opts[:format] }"
    end

    send(date_formatter, date)
  end

  # Usually-correct HTML formatting of a DateTime-ish object
  # Use DateTimeHelper#simple_date with desired formatting options
  #
  # date - a DateTime, Date or Time
  #
  # Returns a String
  def simple_date_html(date)
    date = date.in_time_zone unless date.is_a?(Date)
    time_tag date, simple_date_text(date), title: date.to_s
  end

  # Usually-correct plain text formatting of a DateTime-ish object
  # Use DateTimeHelper#simple_date with desired formatting options
  #
  # date - a DateTime, Date or Time
  #
  # Returns a String
  def simple_date_text(date)
    date = date.in_time_zone.to_date unless date.is_a? Date

    date_format = _('simple_date_format')
    date_format = :long if date_format == 'simple_date_format'
    I18n.l(date, format: date_format)
  end

  # Strips the date from a DateTime
  #
  # date - a DateTime, Date or Time
  #
  # Examples
  #
  #   simple_time(Time.now)
  #   # => "10:46:54"
  #
  # Returns a String
  def simple_time(date)
    date.strftime("%H:%M:%S").strip
  end
end
