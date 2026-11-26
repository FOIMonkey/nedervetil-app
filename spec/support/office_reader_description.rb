# JSON-comparable snapshot of OfficePackage readers. Must stay plain Ruby (no
# Rails) so it can run standalone.
module OfficeReaderDescription
  module_function

  def of(path, max_rows:, max_columns:)
    {
      guard: outcome { OfficePackage::Guard.check!(path) },
      guard_unpack: outcome { OfficePackage::Guard.check!(path, unpack: true) },
      inspector: outcome { OfficePackage::Inspector.findings(path) },
      sheets: outcome do
        OfficePackage::Sheets.read_xlsx(path, max_rows: max_rows,
                                              max_columns: max_columns)
      end,
      whole_sheets: outcome do
        OfficePackage::Sheets.read_xlsx(path, max_rows: nil, max_columns: nil)
      end
    }
  end

  def outcome
    { value: yield }
  rescue OfficePackage::Guard::Refused => e
    { refused: e.reason, values: e.values }
  rescue OfficePackage::Sheets::Refused => e
    { refused: e.reason }
  rescue StandardError => e
    { error: e.class.name, message: e.message }
  end
end
