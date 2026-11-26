require 'csv'
require 'tempfile'

namespace :import do
  desc 'Import public bodies from CSV provided on standard input'
  task import_csv: :environment do
    dryrun = ENV['DRYRUN'] != '0'
    STDERR.puts 'Only a dry run; public bodies will not be created' if dryrun

    tmp_csv = nil
    Tempfile.open('alaveteli') do |f|
      f.write STDIN.read
      tmp_csv = f
    end

    number_of_rows = 0

    STDERR.puts 'Preliminary check for ambiguous names...'

    # Check that each name is unique. Two names that give the same slug are
    # fine: the second body's slug gets a number.
    name_count = Hash.new { 0 }
    reader = CSV.open(tmp_csv.path, 'r')
    header_line = reader.shift
    headers = header_line.map { |h| h.gsub(/^#/, '') }

    reader.each do |row_array|
      row = Hash[headers.zip row_array]
      name_count[row['name']] += 1
      number_of_rows += 1
    end

    non_unique_error = false

    name_count.sort.each do |name, count|
      next unless count > 1

      non_unique_error = true
      STDERR.puts "The name #{name} was found #{count} times."
    end

    next if non_unique_error

    STDERR.puts 'Now importing the public bodies...'

    # Now it's (probably) safe to try to import:
    tag = ''
    tag_behaviour = 'replace'
    editor = "#{ ENV.fetch('USER', nil) } (Unix user)"
    locales = AlaveteliLocalization.available_locales

    import_args = [tmp_csv.path, tag, tag_behaviour, dryrun, editor, locales]

    errors, _notes =
      PublicBody.import_csv_from_file(*import_args) do |row_number, _fields|
        percent_complete = (100 * row_number.to_f / number_of_rows).to_i
        STDERR.print "#{row_number} out of #{number_of_rows} "
        STDERR.puts "(#{percent_complete}% complete)"
      end

    if !errors.empty?
      STDERR.puts 'Import failed, with the following errors:'

      errors.each do |error|
        STDERR.puts "  #{error}"
      end
    else
      STDERR.puts 'Done.'
    end
  end
end
