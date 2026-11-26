require 'spec_helper'

RSpec.describe HealthChecks::Checks::PDFMaskingCheck do
  let(:check) do
    described_class.new(failure_message: 'PDF masking can’t run',
                        success_message: 'PDF masking can run')
  end

  context 'when the sandbox isn’t required' do
    before { allow(PDFRedactor).to receive(:isolated?).and_return(false) }

    it 'passes without running the worker, which masking doesn’t use' do
      expect(PDFRedactor::Isolated).not_to receive(:self_test)
      expect(check).to be_ok
      expect(check.message).to include('masking runs in this process')
    end
  end

  context 'when the sandbox is required' do
    before { allow(PDFRedactor).to receive(:isolated?).and_return(true) }

    it 'passes when the worker runs' do
      allow(PDFRedactor::Isolated).to receive(:self_test)
      expect(check).to be_ok
      expect(check.message).to eq('PDF masking can run: the worker ran')
    end

    it 'says the worker ran in the PDF cell, with converter cells' do
      allow(PDFRedactor::Isolated).to receive(:self_test)
      allow(AlaveteliSandbox::Cell).to receive(:configured?).and_return(true)
      expect(check.message).
        to eq('PDF masking can run: the worker ran in the PDF cell')
    end

    it 'fails, saying why, when the worker can’t run' do
      allow(PDFRedactor::Isolated).to receive(:self_test).
        and_raise(PDFRedactor::Error,
                  'PDF redactor failed: Refused: pdf-redactor: disabled')
      expect(check).not_to be_ok
      expect(check.message).to eq(
        'PDF masking can’t run: PDFRedactor::Error: PDF redactor failed: ' \
        'Refused: pdf-redactor: disabled'
      )
    end

    it 'runs the worker at most once a minute' do
      expect(PDFRedactor::Isolated).to receive(:self_test).twice
      2.times { check.ok? && check.message }
      travel(2.minutes) { check.ok? }
    end

    # Kept in this process only (the check object), and kept as it was.
    it 'keeps a failure as a failure until the worker runs again' do
      allow(PDFRedactor::Isolated).to receive(:self_test).
        and_raise(PDFRedactor::Error, 'PDF redactor failed: timed out')
      expect(check).not_to be_ok

      allow(PDFRedactor::Isolated).to receive(:self_test)
      expect(check).not_to be_ok
      travel(2.minutes) { expect(check).to be_ok }
    end
  end
end
