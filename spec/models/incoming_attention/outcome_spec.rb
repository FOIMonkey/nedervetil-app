require 'spec_helper'

RSpec.describe IncomingAttention::Outcome do
  # A Worker answer; the reading itself is tested in the Worker.
  def result(call = 'all', reasons: [], withheld_under: [], mentions: [], truncated: false)
    { 'contract_version' => 'request-outcome/v2',
      'inference_status' => 'complete',
      'call' => call,
      'reasons' => reasons,
      'withheld_under' => withheld_under,
      'mentions' => mentions,
      'input_truncated' => truncated,
      'error_code' => nil,
      'diagnostics' => { 'scores' => { 'opaque' => 1 }, 'signals' => {} } }
  end

  describe IncomingAttention::Outcome::Signals do
    include_context 'with the UK refusal sections'
    let(:legislation) { Legislation.find('foi') }

    it "uses core's references to find the refusal sections a reply cites" do
      found = described_class.cited(
        'We have applied section 43(2) and s.40(2). Some is published under ' \
        'section 21.',
        legislation
      )
      expect(found).to include('Section 43', 'Section 40', 'Section 21')
    end

    it 'does not read a postcode as a section' do
      expect(described_class.cited('Data Protection Officer, The Arc, Clowne ' \
                                   'S43 4JY',
                                   legislation)).to be_empty
    end

    it 'ignores sections of other Acts, as in scanned statutory notices' do
      ['NOTICE is hereby given that in accordance with Section 30 of the ' \
       'Local Government Finance Act 1992 the Council',
       'Section30 of the Local Government Finance Act ' \
       '1992', 'under sections 12 and 14 of the Housing Act 1985',
       'section 31(1)(a) of the Data Protection Act ' \
       '2018', 'see s.21 of Local Government Act 1972'].each do |text|
        expect(described_class.cited(text, legislation)).to be_empty, text
      end
    end

    it 'keeps sections of the FOI Acts and the EIR' do
      {
        'exempt under section 43(2) of the Freedom of Information Act 2000' =>
          ['Section 43'],
        'section 40(2) of the Act' => ['Section 40'],
        'section 30 of the said Act' => ['Section 30'],
        'section 31 of the 2000 Act' => ['Section 31'],
        'section 21 of FOIA' => ['Section 21'],
        'section 30 of the Freedom of Information (Scotland) Act 2002' =>
          ['Section 30'],
        'withheld under section 31 of the Freedom of Information Act; a ' \
        'notice under section 30 of the Local Government Finance Act' =>
          ['Section 31'],
        'Section 43 of the relevant legislation, the Freedom of ' \
        'Information Act 2000' => ['Section 43'],
        'We rely on section 12 of the legislation (the Freedom of ' \
        'Information Act)' => ['Section 12'],
        'section 36 of, and Schedule 1 to, FOIA' => ['Section 36'],
        'section 40 of what is commonly known as the Act' => ['Section 40'],
        'section 31 of the Data Protection Act 2018 and section 40 of the ' \
        'Freedom of Information Act' => ['Section 40']
      }.each { |text, cited|
        expect(described_class.cited(text, legislation)).to eq(cited), text
      }
      expect(described_class.cited('regulation 12(4)(b) of the applicable ' \
                                   'rules, the Environmental Information ' \
                                   'Regulations',
                                   Legislation.find('eir'))).
        to eq(['Regulation 12'])
      expect(described_class.cited('regulation 12(5)(e) of the Environmental ' \
                                   'Information Regulations 2004',
                                   Legislation.find('eir'))).
        to eq(['Regulation 12'])
    end

    it 'logs a fixed code and finds nothing when the parser fails' do
      allow(legislation).to receive(:find_references).
        and_raise(RegexpError, 'reply text')
      allow(Rails.logger).to receive(:warn).and_call_original
      expect(described_class.cited('section 40', legislation)).to eq([])
      expect(Rails.logger).to have_received(:warn).
        with('request_outcome_citations_failed RegexpError')
    end

    it 'stays fast on long hostile text' do
      [('section 1, 2, 3 and 4 of the ' * 2000) + ('s 1 ' * 5000),
       ('section 1 of ' + ('freedom foi the said ' * 4)) * 1000,
       ('s 1 of ' + ('x' * 79) + ' ') * 500].each do |text|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        described_class.cited(text, legislation)
        # Generous, so a busy machine passes: runaway backtracking takes
        # minutes.
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).
          to be < 10
      end
    end
  end

  describe 'what the requester is told' do
    def row(call, reasons: [], withheld_under: [], mentions: [])
      IncomingAttention::Prediction.new(outcome_call: call, outcome_signals: {
                                          'reasons' => reasons,
                                          'withheld_under' => withheld_under,
                                          'mentions' => mentions
                                        })
    end

    it "names why a release is partial, in the Worker's order" do
      partial = row('some',
                    reasons: %w[exemption_applied cites_refusal part_not_held],
                    withheld_under: ['cost_limit', 'Section 31'])
      expect(described_class.partial_reasons(partial)).
        to eq(['withheld under the cost limit and Section 31', 'part not held'])
      expect(described_class.partial_reasons(
               row('some', reasons: %w[part_unaddressed suppressed])
             )).to eq(['part not answered', 'small numbers withheld'])
      expect(described_class.partial_reasons(
               row('all', withheld_under: ['Section 31'])
             )).to eq([])
    end

    it 'names exemptions, keeping section names as core writes them' do
      expect(described_class.exemptions(
               row('unsure', mentions: %w[ncnd personal_data] + ['Section 40'])
             )).
        to eq(['neither confirm nor deny', 'personal data', 'Section 40'])
      expect(described_class.exemptions(row('all'))).to eq([])
    end

    it 'sends no more text than fits the state, counting the framing, in reading order' do
      input = IncomingAttention::Outcome::Input
      frame = input::FRAME
      docs = [{ 'name' => 'Response.pdf',
                'text' => 'é' * input::SHARE_BYTES,
                'letter' => true }, { 'name' => 'Annex.pdf',
                                      'text' => 'x',
                                      'letter' => false }]
      shared = input.share('How many?',
                           false,
                           'Dear requester',
                           '> quoted',
                           docs)
      expect(shared.slice('request_text', 'reply', 'reply_unfolded')).
        to eq('request_text' => 'How many?',
              'reply' => 'Dear requester',
              'reply_unfolded' => '> quoted')
      expect(shared['documents'].map { |doc| doc['name'] }).
        to eq(['Response.pdf'])
      expect(shared['text_shortened']).to be true
      text = shared['documents'].first['text']
      expect(text).to be_valid_encoding
      framing = frame.values_at(:request, :reply, :unfolded, :open, :letter).sum
      sent = ['How many?',
              'Dear requester',
              '> quoted',
              'Response.pdf',
              text].sum(&:bytesize) + framing
      # Allows for the rest of the character the limit falls in.
      expect(sent).to be_between(input::SHARE_BYTES, input::SHARE_BYTES + 1)
      small = input.share('How many?',
                          true,
                          'Dear requester',
                          nil,
                          docs.map { |doc| doc.merge('text' => 'short') })
      expect(small['documents'].size).to eq(2)
      expect(small).
        to include('reply_unfolded' => nil, 'text_shortened' => false)
    end
  end

  describe '.floor' do
    let(:shortened) {
      { 'text_shortened' => true,
        'strict_documents' => false,
        'omitted_documents' => 0 }
    }
    let(:strict) {
      { 'text_shortened' => false,
        'strict_documents' => true,
        'omitted_documents' => 2 }
    }

    it 'never lets a reading of shortened or incomplete text set a status' do
      expect(described_class.floor(result('all'), shortened)).
        to include('call' => 'unsure', 'reasons' => ['truncated'])
      expect(described_class.floor(
               result('some', reasons: ['cites_refusal'],
                              withheld_under: ['Section 43']),
               strict
             )).
        to include('call' => 'unsure',
                   'reasons' => ['documents_omitted'],
                   'withheld_under' => [])
      expect(described_class.floor(
        result('refused'), strict.merge('strict_documents' => false)
      )['call']).
        to eq('refused')
    end

    it 'leaves holding replies and readings already unsure alone' do
      expect(described_class.floor(result('pending', reasons: ['pending']),
                                   shortened)['call']).to eq('pending')
      expect(described_class.floor(result('unsure', reasons: ['borderline']),
                                   strict)['reasons']).to eq(['borderline'])
    end
  end

  describe IncomingAttention::Outcome::Client do
    before { allow(IncomingAttention::Config).to receive(:enabled?).and_return(true) }
    let(:input) do
      { 'contract_version' => 'request-outcome/v2',
        'message_id' => '1',
        'info_request_id' => '2',
        'request_text' => 'How many?',
        'request_shortened' => false,
        'reply' => 'Four.',
        'reply_unfolded' => nil,
        'documents' => [],
        'text_shortened' => false,
        'omitted_documents' => 0,
        'cited_sections' => [], 'strict_documents' => false }
    end

    def client(status, body)
      described_class.new(transport: ->(_) { [status, JSON.generate(body)] })
    end

    def envelope(extra = {})
      input.slice('contract_version', 'message_id', 'info_request_id').
        merge(result).merge(extra)
    end

    it "returns the Worker's call, reasons and names" do
      expect(client(200, envelope).assess(input)).
        to include('call' => 'all', 'reasons' => [], 'withheld_under' => [])
    end

    it 'rejects unknown calls, malformed lists and mismatched identities' do
      expect {
        client(200, envelope('call' => 'partially_successful')).assess(input)
      }.to raise_error(IncomingAttention::Client::Error,
                       'invalid_worker_response')
      expect {
        client(200, envelope('reasons' => ['Not A Code'])).assess(input)
      }.to raise_error(IncomingAttention::Client::Error)
      expect { client(200, envelope('withheld_under' => [43])).assess(input) }.
        to raise_error(IncomingAttention::Client::Error)
      expect { client(200, envelope('input_truncated' => nil)).assess(input) }.
        to raise_error(IncomingAttention::Client::Error)
      expect { client(200, envelope('message_id' => '9')).assess(input) }.
        to raise_error(IncomingAttention::Client::Error)
    end

    it 'accepts only its own exemption codes and the sections it sent as names' do
      sent = input.merge('cited_sections' => ['Section 43'])
      ok = envelope('call' => 'some',
                    'reasons' => ['cites_refusal'],
                    'withheld_under' => ['Section 43'],
                    'mentions' => ['ncnd', 'Section 43'])
      expect(client(200, ok).assess(sent)).
        to include('mentions' => ['ncnd', 'Section 43'])
      ['Section 99', 'call 0800 000 000', "Section 43\u202E", 'cost limit'].
        each do |name|
        expect { client(200, ok.merge('mentions' => [name])).assess(sent) }.
          to raise_error(IncomingAttention::Client::Error,
                         'invalid_worker_response')
        expect {
          client(200, ok.merge('withheld_under' => [name])).assess(sent)
        }.to raise_error(IncomingAttention::Client::Error,
                         'invalid_worker_response')
      end
    end

    it 'needs the Worker to agree that text it was sent short was shortened' do
      short = input.merge('text_shortened' => true)
      expect { client(200, envelope).assess(short) }.
        to raise_error(IncomingAttention::Client::Error,
                       'invalid_worker_response')
      expect(client(200, envelope('input_truncated' => true)).assess(
        short
      )['input_truncated']).
        to be true
    end

    it 'refuses to send an incomplete request' do
      expect { client(200, envelope).assess(input.except('cited_sections')) }.
        to raise_error(IncomingAttention::Client::Error, 'invalid_request')
    end

    it 'turns Worker errors into retryable or final failures' do
      error = envelope('inference_status' => 'unavailable',
                       'call' => nil,
                       'error_code' => 'provider_timeout')
      expect { client(504, error).assess(input) }.
        to(raise_error { |e|
          expect(e).to have_attributes(code: 'provider_timeout',
                                       retryable: true)
        })
    end

    it 'logs which error it reports as a transport failure, by its class' do
      failing = described_class.new(transport: ->(_) { raise 'Four.' })
      allow(Rails.logger).to receive(:warn).and_call_original
      expect { failing.assess(input) }.
        to(raise_error(IncomingAttention::Client::Error,
                       'transport_failure') { |e|
          expect(e).to have_attributes(status: 'unavailable', retryable: true)
        })
      expect(Rails.logger).to have_received(:warn).
        with('request_outcome_assess_failed RuntimeError')
    end
  end

  describe 'checking a reply and setting the request status' do
    include_context 'with lean attention predictions'
    let(:request) { FactoryBot.create(:info_request) }
    let!(:message) { lean_response(request, 'REVIEW') }
    let(:row) { IncomingAttention::Prediction.for_message(message) }
    let(:answer) { result }
    let(:built) do
      IncomingAttention::Outcome::Input::Built.new(
        signals: { 'cited' => [], 'folded' => false },
        request: { 'contract_version' => 'request-outcome/v2',
                   'message_id' => message.id.to_s,
                   'info_request_id' => request.id.to_s }
      )
    end

    before do
      allow(AlaveteliConfiguration).
        to receive(:incoming_outcome_mode).and_return('apply')
      allow(IncomingAttention::Outcome::Job).to receive(:perform_later)
      allow(IncomingAttention::Outcome::Input).
        to receive(:build).and_return(built)
      allow(IncomingAttention::Outcome::Input).to receive(:recheck!)
      client = double('outcome client', assess: answer)
      allow(IncomingAttention::Outcome::Job).
        to receive(:client_factory).and_return(-> { client })
    end

    def check!
      IncomingAttention::Outcome.queue(row, message)
      IncomingAttention::Outcome::Job.new.perform(row.id)
      row.reload
    end

    it 'sets all information, keeps the reply on the dashboard and labels it' do
      check!
      expect(row).
        to have_attributes(outcome_status: 'complete',
                           outcome_call: 'all',
                           outcome_applied_state: 'successful',
                           auto_classified: true,
                           outcome_scores: { 'opaque' => 1 })
      expect(row.outcome_signals).
        to include('cited' => [], 'reasons' => [], 'truncated' => false)
      expect(request.reload).
        to have_attributes(described_state: 'successful',
                           awaiting_description: false)
      expect(IncomingAttention::Labels.for_message(message)).
        to eq('All information released')
      expect(IncomingAttention::Effective.reviewed?(message)).to be false
    end

    context 'with a nil return' do
      let(:answer) { result('all', reasons: ['nil_return']) }

      it 'counts it as successful but labels it as none existing' do
        check!
        expect(request.reload.described_state).to eq('successful')
        expect(IncomingAttention::Labels.for_message(message)).
          to eq('Information released: nil return')
      end
    end

    context 'when the information is not held' do
      let(:answer) { result('not_held', reasons: ['not_held']) }

      it "stores this site's single No information state but says not held" do
        check!
        expect(request.reload.described_state).to eq('rejected')
        expect(row.outcome_applied_state).to eq('rejected')
        expect(IncomingAttention::Labels.for_message(message)).
          to eq('No information: not held')
      end
    end

    context 'when the reply asks the requester to clarify' do
      let(:answer) { result('clarification', reasons: ['clarification']) }

      it 'sets waiting for clarification, which is not a decision' do
        check!
        expect(request.reload.described_state).to eq('waiting_clarification')
        expect(IncomingAttention::Labels.for_message(message)).
          to eq('Clarification requested')
        expect(Deadlines::Stage.decision?(request,
                                          message.response_event.
                                            reload)).to be false
      end
    end

    context 'when the text had to be shortened but the Worker still answers' do
      let(:built) do
        IncomingAttention::Outcome::Input::Built.new(
          signals: { 'cited' => [], 'folded' => false },
          request: { 'contract_version' => 'request-outcome/v2',
                     'message_id' => message.id.to_s,
                     'info_request_id' => request.id.to_s,
                     'text_shortened' => true,
                     'strict_documents' => false,
                     'omitted_documents' => 0 }
        )
      end

      it 'is not sure and sets nothing' do
        check!
        expect(row).
          to have_attributes(outcome_call: 'unsure', outcome_applied_state: nil)
        expect(row.outcome_signals['reasons']).to eq(['truncated'])
        expect(request.reload.awaiting_description?).to be true
      end
    end

    it 'counts an automatic outcome as the decision a review would be asked about' do
      check!
      expect(Deadlines::Stage.decision?(request,
                                        message.response_event.
                                          reload)).to be true
    end

    context 'when the reply is refused' do
      let(:answer) { result('refused', reasons: ['refused']) }

      it 'gives the dashboard the same review action as the request page' do
        check!
        action = Deadlines::Overview.actions(request.user).find { |a| a.request.id == request.id }
        expect(action&.kind).to eq(:ask_review)
      end
    end

    it 'drops the automatic label once a person changes the status' do
      check!
      request.reload.set_described_state('rejected', request.user)
      expect(IncomingAttention::Labels.for_message(message.reload)).
        not_to eq('All information released')
    end

    it 'forgets the reading on invalidation but keeps the decision for deadlines' do
      check!
      row.invalidate!(reason: 'raw_erased')
      expect(row.reload).
        to have_attributes(outcome_applied_state: 'successful',
                           outcome_status: nil,
                           outcome_call: nil,
                           outcome_scores: nil)
      expect(IncomingAttention::Labels.for_message(message.reload)).
        not_to eq('All information released')
      request.deadlines_auto_classified_ids = nil
      expect(Deadlines::Stage.decision?(request.reload,
                                        message.response_event.
                                          reload)).to be true
    end

    it 'records a person changing the automatic outcome' do
      check!
      request.reload.set_described_state('partially_successful', request.user)
      expect(row.reload).
        to have_attributes(outcome_overridden_from: 'successful')
      expect(row.human_reviewed_at).to be_present
    end

    context 'when Clef is not sure' do
      let(:answer) { result('unsure', reasons: ['borderline']) }

      it 'leaves the question to the requester and says so' do
        check!
        expect(row.outcome_call).to eq('unsure')
        expect(row.outcome_applied_state).to be_nil
        expect(request.reload.awaiting_description?).to be true
        expect(IncomingAttention::Labels.for_message(message)).
          to eq('Outcome unclear: please check')
      end
    end

    it 'only stores the reading in shadow mode' do
      allow(AlaveteliConfiguration).
        to receive(:incoming_outcome_mode).and_return('shadow')
      check!
      expect(row.outcome_call).to eq('all')
      expect(request.reload.awaiting_description?).to be true
      expect(IncomingAttention::Labels.for_message(message)).
        not_to eq('All information released')
    end

    it 'never checks routine replies' do
      row.update!(route: 'SKIP', needs_check: false)
      IncomingAttention::Outcome.queue(row, message)
      expect(row.reload.outcome_status).to be_nil
    end

    it 'leaves the request alone when the Worker fails, and retries later' do
      client = double('outcome client')
      allow(client).
        to receive(:assess).and_raise(IncomingAttention::Client::Error.new(
                                        'provider_timeout',
          status: 'unavailable',
          retryable: true
                                      ))
      allow(IncomingAttention::Outcome::Job).
        to receive(:client_factory).and_return(-> { client })
      allow(Rails.logger).to receive(:warn).and_call_original
      check!
      expect(row).
        to have_attributes(outcome_status: 'pending', outcome_attempts: 1)
      expect(request.reload.awaiting_description?).to be true
      expect(Rails.logger).to have_received(:warn).
        with("request_outcome_check_failed prediction_id=#{row.id} " \
             'code=provider_timeout')
    end

    it 'logs which error an unexpected failure was, by its class' do
      client = double('outcome client')
      allow(client).to receive(:assess).and_raise(NoMethodError, 'reply text')
      allow(IncomingAttention::Outcome::Job).
        to receive(:client_factory).and_return(-> { client })
      allow(Rails.logger).to receive(:warn).and_call_original
      check!
      expect(row).
        to have_attributes(outcome_status: 'failed',
                           outcome_signals: { 'error' => 'unexpected_failure' })
      expect(request.reload.awaiting_description?).to be true
      expect(Rails.logger).to have_received(:warn).
        with("request_outcome_check_failed prediction_id=#{row.id} " \
             'code=unexpected_failure NoMethodError')
    end

    it 'logs which error stopped the check being queued, by its class' do
      allow(IncomingAttention::Outcome::Job).
        to receive(:perform_later).and_raise(NoMethodError, 'reply text')
      allow(Rails.logger).to receive(:warn).and_call_original
      expect { IncomingAttention::Outcome.queue(row, message) }.
        not_to raise_error
      expect(row.reload.outcome_status).to eq('pending')
      expect(Rails.logger).to have_received(:warn).
        with("request_outcome_enqueue_failed prediction_id=#{row.id} " \
             'NoMethodError')
    end

    it 'does not overwrite a status the requester already gave' do
      request.set_described_state('rejected', request.user)
      check!
      expect(request.reload.described_state).to eq('rejected')
      expect(row.outcome_applied_state).to be_nil
    end
  end

  describe '.partial_reasons' do
    it 'returns an empty array when outcome_signals is nil' do
      prediction = IncomingAttention::Prediction.new(
        outcome_call: 'some',
        outcome_signals: nil
      )
      expect(described_class.partial_reasons(prediction)).to eq([])
    end
  end
end
