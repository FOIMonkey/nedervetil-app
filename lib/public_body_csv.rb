require 'csv'

# Exports public bodies with configurable fields and headers.
#
#   csv = PublicBodyCSV.new(fields: [:name], headers: ['Name'])
#   bodies.each { |body| csv << body }
#   csv.generate # => CSV string
class PublicBodyCSV
  def self.default_fields
    [:id,
     :name,
     :short_name,
     :url_name,
     :tag_string,
     :calculated_home_page,
     :publication_scheme,
     :disclosure_log,
     :notes_as_string,
     :created_at,
     :updated_at,
     :version]
  end

  # TODO: Generate headers from fields
  def self.default_headers
    ['Internal ID',
     'Name',
     'Short name',
     'URL name',
     'Tags',
     'Home page',
     'Publication scheme',
     'Disclosure log',
     'Notes',
     'Created at',
     'Updated at',
     'Version']
  end

  def self.export
    csv = new

    PublicBody.includes(:translations, :tags).visible.find_each do |public_body|
      next if public_body.site_administration?

      csv << public_body
    end

    csv.generate
  end

  attr_reader :fields, :headers, :rows

  def initialize(args = {})
    @fields = args.fetch(:fields, self.class.default_fields)
    @headers = args.fetch(:headers, self.class.default_headers)
    @rows = []
  end

  def <<(public_body)
    rows << CSV.generate_line(collect_public_body_attributes(public_body),
                              row_sep: '')
  end

  # TODO: Just use CSV.generate
  def generate
    csv = CSV.generate_line(headers)
    csv << join_rows
    csv << "\n"
  end

  private

  def join_rows
    rows.join("\n")
  end

  def collect_public_body_attributes(public_body)
    fields.map do |field|
      if public_body.respond_to?(field) && public_body.send(field)
        public_body.send(field)
      else
        ''
      end
    end
  end
end
