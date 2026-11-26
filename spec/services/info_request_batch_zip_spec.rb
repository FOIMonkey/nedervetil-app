require 'spec_helper'

RSpec.describe InfoRequestBatchZip do
  let(:batch) do
    FactoryBot.create(:info_request_batch, info_requests: [request])
  end
  let(:ability) { Object.new.extend(CanCan::Ability) }
  let(:request) { FactoryBot.build(:info_request) }

  let(:instance) { described_class.new(batch, ability: ability) }

  describe 'initialisation' do
    it 'stores info_request_batch' do
      expect(instance.info_request_batch).to eq batch
    end

    it 'stores ability' do
      expect(instance.ability).to eq ability
    end

    it 'keeps untrusted names within one ZIP path component' do
      component = instance.send(:safe_zip_component,
                                "../private\\file:one\n.txt")
      expect(component).not_to match(%r{[/\\:\x00-\x1f]})
      expect(component).not_to eq('..')
      expect(instance.send(:safe_zip_component, '..')).to eq('_')
      expect(instance.send(:safe_zip_component, '.')).to eq('_')
      expect(instance.send(:safe_zip_component, 'Annual report..pdf')).
        to eq('Annual report..pdf')
    end
  end

  describe '#files' do
    subject(:files) { instance.files }
    let(:paths) { files.map(&:path) }

    let(:base_path) do
      [request.public_body.name, request.url_title].join(' - ')
    end

    before do
      # stub metrics service
      allow(InfoRequestBatchMetrics).to receive(:new).
        with(batch, ability: ability).
        and_return(double(:metrics, name: 'NAME', to_csv: 'CSV_DATA'))
      ability.can :read, InfoRequest
    end

    around do |example|
      travel_to Time.utc(2019, 11, 18, 10, 30)
      example.call
      travel_back
    end

    it 'generates list of zippable files' do
      is_expected.to all(be_a described_class::ZippableFile)
    end

    # Its attachments can't be listed, and leaving them out would not show.
    it 'is not made of a reply whose mail can’t be read now' do
      batch
      receive_incoming_mail('incoming-request-two-same-name.eml',
                            to: request.incoming_email)
      ability.can :read, IncomingMessage
      allow(MailHandler::Reading).to receive(:of).
        and_raise(MailHandler::ReadRefused, 'the mail cell is down')
      allow(Rails.logger).to receive(:warn)

      expect { files.to_a }.to raise_error(MailHandler::ReadRefused)
    end

    it 'serves stored reply text without re-reading the email once parsed' do
      batch
      receive_incoming_mail('incoming-request-plain.eml',
                            to: request.incoming_email)
      request.incoming_messages.last.parse_raw_email
      request.expire
      ability.can :read, IncomingMessage
      ability.can :read, FoiAttachment
      allow(MailHandler::Reading).to receive(:of).
        and_raise(MailHandler::ReadRefused, 'the mail cell is down')

      expect { files.to_a }.not_to raise_error
    end

    it 'reads no mail for a reply the person may not read' do
      batch
      receive_incoming_mail('incoming-request-two-same-name.eml',
                            to: request.incoming_email)
      expect(MailHandler::Reading).not_to receive(:of)

      expect(files.map(&:path)).to eq(['NAME'])
    end

    it 'includes batch metrics at the root' do
      is_expected.to include(
        described_class::ZippableFile.new('NAME', 'CSV_DATA')
      )
    end

    context 'when batch info request has been sent' do
      let(:event) { FactoryBot.create(:sent_event, info_request: request) }
      let(:message) { event.outgoing_message }

      context 'can read message' do
        before { ability.can :read, message }

        it 'includes outgoing message' do
          expect(paths).to include(
            "#{base_path}/2019-11-04-103000/outgoing_#{message.id}.txt"
          )
        end
      end

      context 'cannot read message' do
        before { ability.cannot :read, message }

        it 'does not include outgoing message' do
          expect(paths).not_to include(
            "#{base_path}/2019-11-04-103000/outgoing_#{message.id}.txt"
          )
        end
      end
    end

    context 'when batch info request has responses' do
      let(:event) { FactoryBot.create(:response_event, info_request: request) }
      let(:message) { event.incoming_message }

      context 'can read message' do
        before do
          ability.can :read, message
          ability.can :read, message.get_main_body_text_part
        end

        it 'includes incoming message' do
          expect(paths).to include(
            "#{base_path}/2019-11-11-103000/incoming_#{message.id}.txt"
          )
        end
      end

      context 'cannot read message' do
        before { ability.cannot :read, message }

        it 'does not include incoming message' do
          expect(paths).not_to include(
            "#{base_path}/2019-11-11-103000/incoming_#{message.id}.txt"
          )
        end
      end
    end

    context 'when batch info request has attachments' do
      let(:event) do
        FactoryBot.create(
          :response_event, :with_attachments, info_request: request
        )
      end

      let(:message) { event.incoming_message }
      let(:attachment) { message.get_attachments_for_display.first }

      context 'can read message and attachment' do
        before do
          ability.can :read, message
          ability.can :read, attachment
        end

        it 'includes attachments' do
          expect(paths).to include(
            "#{base_path}/2019-11-11-103000/attachments-#{message.id}/" \
              "#{attachment.display_filename}"
          )
        end

        it 'uses the attachment body after masking' do
          allow_any_instance_of(FoiAttachment).to receive(:masked_default_body).
            and_return('synthetic-redacted-content')
          file = files.find do |item|
            item.path.end_with?(attachment.display_filename)
          end
          expect(file.body).to eq('synthetic-redacted-content')
        end

        it 'keeps an unsafe attachment filename inside its ZIP directory' do
          allow_any_instance_of(FoiAttachment).to receive(:display_filename).
            and_return('../private.pdf')
          expect(paths).to include(
            "#{base_path}/2019-11-11-103000/" \
            "attachments-#{message.id}/.._private.pdf"
          )
        end
      end

      context 'cannot read message' do
        before do
          ability.cannot :read, message
          ability.can :read, attachment
        end

        it 'does not include attachments' do
          expect(paths).not_to include(
            "#{base_path}/2019-11-11-103000/attachments-#{message.id}/" \
              "#{attachment.display_filename}"
          )
        end
      end

      context 'cannot read attachment' do
        before do
          ability.can :read, message
          ability.cannot :read, attachment
        end

        it 'does not include attachments' do
          expect(paths).not_to include(
            "#{base_path}/2019-11-11-103000/attachments-#{message.id}/" \
              "#{attachment.display_filename}"
          )
        end
      end

      context 'when a censor rule redacts an attachment filename' do
        before do
          ability.can :read, message
          ability.can :read, attachment
        end

        it 'uses the redacted filename in the zip path' do
          request.censor_rules.create!(
            text: 'interesting', replacement: 'REDACTED',
            last_edit_editor: 'unknown', last_edit_comment: 'none'
          )

          attachment_path =
            "#{base_path}/2019-11-11-103000/attachments-#{message.id}"

          expect(paths).to include("#{attachment_path}/REDACTED.pdf")
          expect(paths).not_to include("#{attachment_path}/interesting.pdf")
        end
      end
    end
  end

  describe '#name' do
    let(:batch) { double(:info_request_batch, id: 1, title: 'Batch Request') }
    subject(:name) { instance.name }

    it 'returns a useful filename' do
      travel_to Time.utc(2019, 11, 18, 10, 30)
      is_expected.to(
        eq 'batch-1-batch_request-export-2019-11-18-103000.zip'
      )
      travel_back
    end
  end

  it 'does not include a hidden message body for a batch owner' do
    owner = FactoryBot.create(:pro_user)
    request = FactoryBot.create(:info_request_with_incoming, user: owner)
    batch = FactoryBot.create(:info_request_batch,
                              user: owner,
                              info_requests: [request])
    body_part = request.incoming_messages.first.get_main_body_text_part
    body_part.update!(prominence: 'hidden', prominence_reason: 'private')

    ability = Ability.new(owner)
    expect(ability.can?(:download, batch)).to be true
    expect(ability.can?(:read, body_part)).to be false

    incoming_file = described_class.new(batch, ability: ability).files.
      find { |file| file.path.include?('/incoming_') }
    expect(incoming_file).to be_nil
  end
end
