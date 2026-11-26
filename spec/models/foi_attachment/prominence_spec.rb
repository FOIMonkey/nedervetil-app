require 'spec_helper'

RSpec.describe FoiAttachment::Prominence do
  let(:earlier) { Time.zone.local(2026, 1, 2, 3, 4, 5) }
  let(:at) { Time.zone.local(2026, 2, 3, 4, 5, 6) }
  let(:attachment) do
    FactoryBot.create(:body_text, prominence: 'requester_only',
                                  prominence_reason: 'Held for a check')
  end

  def stored
    FoiAttachment.find(attachment.id)
  end

  describe '#make_public!' do
    it 'makes the file public at the time given' do
      attachment.make_public!(at: at)

      expect(stored).to have_attributes(prominence: 'public', updated_at: at)
    end

    it 'uses the time now when none is given' do
      travel_to(at) { attachment.make_public! }

      expect(stored.updated_at).to eq(at)
    end

    it 'changes nothing else about the file' do
      attachment.update_columns(black_masked: true, masking_failed_at: earlier)
      attachment.make_public!(at: at)

      expect(stored).to have_attributes(
        prominence_reason: 'Held for a check',
        black_masked: true,
        masking_failed_at: earlier,
        erased_at: nil
      )
    end
  end

  describe '#make_requester_only!' do
    before { attachment.update_columns(prominence: 'public') }

    it 'leaves the file to its requester at the time given' do
      attachment.make_requester_only!(at: at)

      expect(stored).
        to have_attributes(prominence: 'requester_only', updated_at: at)
    end

    it 'uses the time now when none is given' do
      travel_to(at) { attachment.make_requester_only! }

      expect(stored.updated_at).to eq(at)
    end

    it 'changes nothing else about the file' do
      attachment.update_columns(black_masked: true, masking_failed_at: earlier)
      attachment.make_requester_only!(at: at)

      expect(stored).to have_attributes(
        prominence_reason: 'Held for a check',
        black_masked: true,
        masking_failed_at: earlier,
        erased_at: nil
      )
    end

    it 'does not look at what the file was before' do
      attachment.update_columns(prominence: 'hidden')
      attachment.make_requester_only!

      expect(stored.prominence).to eq('requester_only')
    end
  end

  describe '#hide_for_black_rule!' do
    it 'hides the file, with the reason, as black masked and failed now' do
      travel_to(at) { attachment.hide_for_black_rule!(reason: 'A rule hit.') }

      expect(stored).to have_attributes(
        prominence: 'hidden',
        prominence_reason: 'A rule hit.',
        black_masked: true,
        masking_failed_at: at,
        updated_at: at,
        erased_at: nil
      )
    end

    it 'keeps the time masking first failed' do
      attachment.update_columns(masking_failed_at: earlier)
      travel_to(at) { attachment.hide_for_black_rule!(reason: 'A rule hit.') }

      expect(stored).
        to have_attributes(masking_failed_at: earlier, updated_at: at)
    end
  end

  describe '#hide_as_erased!' do
    it 'marks the file erased and hidden at the time given' do
      attachment.hide_as_erased!(at: at)

      expect(stored).to have_attributes(
        prominence: 'hidden',
        erased_at: at,
        updated_at: at,
        prominence_reason: 'Held for a check',
        black_masked: false
      )
    end
  end

  describe 'what every write leaves out' do
    writes = {
      make_public!: ->(file) { file.make_public! },
      make_requester_only!: ->(file) { file.make_requester_only! },
      hide_for_black_rule!: ->(file) { file.hide_for_black_rule!(reason: 'x') },
      hide_as_erased!: ->(file) { file.hide_as_erased!(at: Time.current) }
    }

    before { attachment.update_columns(prominence: 'hidden') }

    it 'is unlike an ordinary save, which tells the attention reading' do
      expect(IncomingAttention::Prediction).to receive(:invalidate_message).
        with(attachment.incoming_message_id, 'attachment_visibility_changed')

      attachment.update!(prominence: 'public')
    end

    it 'is unlike an ordinary save, which refuses an invalid file' do
      attachment.update_columns(display_size: nil)

      expect { stored.update!(prominence: 'public') }.
        to raise_error(ActiveRecord::RecordInvalid)
    end

    writes.each do |name, write|
      it "#{name} does not tell the attention reading" do
        expect(IncomingAttention::Prediction).
          not_to receive(:invalidate_message)

        write.call(attachment)
      end

      it "#{name} writes to a file that would not pass validation" do
        attachment.update_columns(display_size: nil)

        expect { write.call(stored) }.to(change { stored.updated_at })
      end
    end
  end
end
