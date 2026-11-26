require 'spec_helper'

RSpec.describe Disclosures::RuleJob do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request) }

  def published(name, text)
    document = delivered_document(info_request, name, 'text/plain', text)
    publish(document, by: admin)
  end

  # The second alternative backtracks without end on a long run of a's.
  def save_slow_pattern_rule
    FactoryBot.create(:censor_rule, censorable: info_request,
                                    regexp: true,
                                    text: 'SecretTerm|^(a|a)*\1$',
                                    replacement: '[removed]')
  end

  def with_short_regexp_timeout
    timeout = Regexp.timeout
    Regexp.timeout = 0.1
    yield
  ensure
    Regexp.timeout = timeout
  end

  def state_of(document)
    document.reload
    file = FoiAttachment.find(document.foi_attachment_id)
    { listed: document.listed?,
      prominence: file.prominence,
      words_removed: file.file.download.exclude?('SecretTerm') }
  end

  it 'takes down a file whose title a saved rule runs out of time on, and ' \
     'still checks the files after it' do
    first = published('first.txt', "Notes with nothing to remove.\n")
    first.update_columns(title: "#{'a' * 40}!")
    later = published('later.txt', "Notes mentioning SecretTerm.\n")

    rule = with_short_regexp_timeout do
      perform_enqueued_jobs(only: described_class) { save_slow_pattern_rule }
    end

    expect(first: state_of(first),
           later: state_of(later),
           finished: rule.reload.masking_finished_at.present?).to eq(
             first: { listed: false, prominence: 'requester_only',
                      words_removed: true },
             later: { listed: true, prominence: 'public',
                      words_removed: true },
             finished: true
           )
  end

  context 'when a file fails on every try' do
    let(:failure) { ActiveStorage::FileNotFoundError.new('synthetic') }

    def save_rule
      perform_enqueued_jobs(only: described_class) do
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        text: 'SecretTerm',
                                        replacement: '[removed]')
      end
    end

    before do
      allow_any_instance_of(described_class).
        to receive(:send_exception_notifications?).and_return(true)
      allow(ExceptionNotifier).to receive(:notify_exception)
    end

    it 'reports it, checks the files after it, and leaves the rule ' \
       'unfinished' do
      first = published('first.txt', "Notes mentioning SecretTerm.\n")
      later = published('later.txt', "More notes mentioning SecretTerm.\n")
      bad_id = first.foi_attachment_id
      tries = 0
      allow(Disclosures::RuleRemask).to receive(:apply_to_attachment!).
        and_wrap_original do |original, attachment, rule|
          if attachment.id == bad_id
            tries += 1
            raise failure
          end
          original.call(attachment, rule)
        end

      rule = save_rule

      expect(tries).to eq(described_class::TRIES)
      expect(first: state_of(first),
             later: state_of(later),
             finished: rule.reload.masking_finished_at.present?).to eq(
               first: { listed: true, prominence: 'public',
                        words_removed: false },
               later: { listed: true, prominence: 'public',
                        words_removed: true },
               finished: false
             )
      expect(ExceptionNotifier).to have_received(:notify_exception).once.
        with(failure, data: hash_including(censor_rule_id: rule.id,
                                           attachment_id: bad_id))
    end

    it 'still applies a changed black rule when undoing its old masks ' \
       'fails on a file' do
      masked = published('masked.txt', "Notes with nothing to remove.\n")
      later = published('later.txt', "Notes mentioning SecretTerm.\n")
      rule = FactoryBot.create(:censor_rule, censorable: info_request,
                                             text: 'OtherTerm',
                                             replacement: '[removed]')
      FoiAttachment.where(id: masked.foi_attachment_id).
        update_all(prominence: 'hidden', black_masked: true)
      allow(Disclosures::RuleRemask).
        to receive(:remask_after_removal!).and_raise(failure)

      perform_enqueued_jobs(only: described_class) do
        rule.update!(text: 'SecretTerm')
      end

      expect(later: state_of(later),
             finished: rule.reload.masking_finished_at.present?).to eq(
               later: { listed: true, prominence: 'public',
                        words_removed: true },
               finished: false
             )
    end
  end
end
