require 'spec_helper'

RSpec.describe HealthChecks::Checks::OfficeWorkerCheck do
  let(:check) do
    described_class.new(failure_message: 'The Office worker can’t run',
                        success_message: 'The Office worker can run')
  end

  context 'when the sandbox isn’t required' do
    it 'passes without running the worker, which nothing runs then' do
      expect(OfficePackage::Isolated).not_to receive(:self_test)
      expect(check).to be_ok
      expect(check.message).to include('read in this process')
    end
  end

  context 'when the sandbox is required' do
    before do
      allow(AlaveteliConfiguration).
        to receive(:sandbox_converters).and_return('required')
    end

    it 'passes when the worker runs' do
      allow(OfficePackage::Isolated).to receive(:self_test)
      expect(check).to be_ok
      expect(check.message).to eq('The Office worker can run: the worker ran')
    end

    it 'says the worker ran in the Office cell, with converter cells' do
      allow(OfficePackage::Isolated).to receive(:self_test)
      allow(AlaveteliSandbox::Cell).to receive(:configured?).and_return(true)
      expect(check.message).
        to eq('The Office worker can run: the worker ran in the Office cell')
    end

    it 'fails, saying why, when the worker can’t run' do
      allow(OfficePackage::Isolated).to receive(:self_test).
        and_raise(AlaveteliSandbox::Refused,
                  'the office converter cell refused the step: this cell ' \
                  'has not been told the Office worker’s gems')
      expect(check).not_to be_ok
      expect(check.message).to eq(
        'The Office worker can’t run: AlaveteliSandbox::Refused: the office ' \
        'converter cell refused the step: this cell has not been told the ' \
        'Office worker’s gems'
      )
    end

    it 'runs the worker at most once a minute' do
      expect(OfficePackage::Isolated).to receive(:self_test).twice
      2.times { check.ok? && check.message }
      travel(2.minutes) { check.ok? }
    end
  end
end
