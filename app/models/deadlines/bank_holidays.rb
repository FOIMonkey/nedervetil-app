module Deadlines
  # Bank holidays in each part of the UK, from a theme's
  # data/bank_holidays.json (in the format of www.gov.uk/bank-holidays.json).
  # Without one, Calendar uses core's holidays table.
  module BankHolidays
    DIVISIONS = %w[england-and-wales scotland northern-ireland].freeze

    module_function

    def division(name)
      @divisions ||= {}
      @divisions[name] ||= events(name).
        to_set { |event| Date.iso8601(event.fetch('date')) }.freeze
    end

    def scotland
      division('scotland')
    end

    # Every part of the UK, as FOIA s.10(6) counts.
    def uk
      @uk ||= DIVISIONS.map { |name| division(name) }.reduce(:|).freeze
    end

    def last_day
      @last_day ||= uk.max || Date.new(0)
    end

    def events(name)
      file = ThemeData.file('bank_holidays.json') or return []
      JSON.parse(File.read(file)).fetch(name).fetch('events')
    end
  end
end
