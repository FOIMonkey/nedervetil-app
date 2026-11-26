# ExcelAnalyzer

This gem packages Active Storage analyzers that inspect uploaded spreadsheets,
ZIP archives and Office files for hidden data (hidden sheets, rows, columns,
comments, pivot caches, external links, named ranges, macros and embedded
workbooks), recording counts in blob metadata.

In this fork it reads workbooks with `OfficePackage::ExcelMetadata` (via the
Office converter sandbox when enabled) rather than `rubyXL`, and covers
`.xlsx`, `.xlsm`, `.xltx`, `.xltm`, `.xls`, `.xlsb`, ZIP archives
(`ExcelAnalyzer::ZipAnalyzer`) and embedded spreadsheets inside Word and
PowerPoint packages (`ExcelAnalyzer::OfficeEmbeddedAnalyzer`). See
`doc/FORK.md`.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run
`rake spec` to run the tests. You can also run `bin/console` for an interactive
prompt that will allow you to experiment.

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/mysociety/alaveteli
