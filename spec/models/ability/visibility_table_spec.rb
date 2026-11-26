require 'spec_helper'

RSpec.describe 'Who sees what: the table' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  def self.viewers
    %i[visitor other requester banned_requester closed_requester
       admin banned_admin closed_admin]
  end

  # R = any requester, r = active requester, A = active admin.
  def self.seen(names)
    letters = names.split
    viewers.index_with do |viewer|
      case viewer
      when :requester then letters.intersect?(%w[R r])
      when :banned_requester, :closed_requester then letters.include?('R')
      when :admin then letters.include?('A')
      else false
      end
    end
  end

  delegate :seen, to: :class

  let(:requester) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:other) { FactoryBot.create(:user, name: 'Olive Other') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:banned_admin) { FactoryBot.create(:admin_user, ban_text: 'Synthetic') }
  let(:closed_admin) do
    FactoryBot.create(:admin_user, closed_at: Time.current)
  end

  def new_request(prominence = 'requester_only')
    FactoryBot.create(:info_request, user: requester, prominence: prominence)
  end

  def reply_to(request, name = 'runs.txt', type = 'text/plain')
    AttachmentFixtures.deliver(request, [[name, type, "Gritting runs: 12\n"]])
  end

  def hide(record, prominence)
    reason = 'Synthetic' unless %w[normal public].include?(prominence)
    record.update!(prominence: prominence, prominence_reason: reason)
  end

  def set_file(file, state)
    case state
    when 'erased' then file.update_columns(erased_at: Time.current)
    when 'none' then file.update_column(:prominence, nil)
    else hide(file, state)
    end
  end

  # Mutates the same requester account in place (active -> banned -> closed).
  def each_viewer
    yield :visitor, nil
    yield :other, other
    yield :requester, requester
    requester.update!(ban_text: 'Synthetic ban')
    yield :banned_requester, requester
    requester.update!(ban_text: '')
    requester.close!
    yield :closed_requester, requester
    yield :admin, admin
    yield :banned_admin, banned_admin
    yield :closed_admin, closed_admin
  end

  def in_inbox?(user, reply)
    requests = IncomingAttention::Effective.visible_requests(user)
    IncomingAttention::Effective.unresolved(
      IncomingMessage.where(id: reply.id, info_request_id: requests.select(:id))
    ).exists?
  end

  # FollowupsController requires :read in addition to :follow_up.
  def follows_up?(ability, request)
    ability.can?(:follow_up, request) && ability.can?(:read, request)
  end

  def cells(request, reply, file)
    answers = Hash.new { |hash, key| hash[key] = {} }
    each_viewer do |viewer, user|
      ability = Ability.new(user&.reload)
      answers[:request][viewer] = ability.can?(:read, request.reload)
      answers[:reply][viewer] = ability.can?(:read, reply.reload)
      answers[:file][viewer] = ability.can?(:read, file.reload)
      answers[:follow_up][viewer] = follows_up?(ability, request)
      answers[:inbox][viewer] = in_inbox?(user, reply)
    end
    answers
  end

  def readers(request, reply, file)
    visible = Ability::RequesterVisible
    ability = Ability.new(request.user)
    {
      request: {
        ability: ability.can?(:read, request),
        requester_visible: visible.requester?(request),
        visible_to_requester_query:
          InfoRequest.visible_to_requester.exists?(request.id)
      },
      reply: {
        ability: ability.can?(:read, reply),
        requester_visible: visible.requester?(reply),
        effective: IncomingAttention::Effective.
          relation(IncomingMessage.where(id: reply.id)).exists?
      },
      file: {
        ability: ability.can?(:read, file),
        requester_visible: visible.requester?(file),
        visibility_words: AttachmentManagement::Visibility.describe(file) ==
          'The requester and admins only. Not published.'
      }
    }
  end

  def agree?(answers)
    answers.values.uniq.size == 1
  end

  describe 'a request, a reply and a file' do
    columns = %i[request reply file follow_up inbox]
    follow_up_actions = %i[follow_up send_reminder]

    # rubocop:disable Layout/LineLength
    # request          reply             file              request reply  file   follow inbox
    [
      ['requester_only', 'normal',         'public',         'R A', 'R A', 'R A', 'r', 'R'],
      ['requester_only', 'normal',         'requester_only', 'R A', 'R A', 'R A', 'r', 'R'],
      ['requester_only', 'normal',         'hidden',         'R A', 'R A', 'A',   'r', 'R'],
      ['requester_only', 'normal',         'erased',         'R A', 'R A', '',    'r', 'R'],
      ['requester_only', 'hidden',         'public',         'R A', 'A',   'A',   'r', ''],
      ['requester_only', 'hidden',         'requester_only', 'R A', 'A',   'A',   'r', ''],
      ['requester_only', 'hidden',         'hidden',         'R A', 'A',   'A',   'r', ''],
      ['requester_only', 'hidden',         'erased',         'R A', 'A',   '',    'r', ''],
      ['hidden',         'normal',         'public',         'A',   'A',   'A',   '',  ''],
      ['hidden',         'normal',         'requester_only', 'A',   'A',   'A',   '',  ''],
      ['hidden',         'normal',         'hidden',         'A',   'A',   'A',   '',  ''],
      ['hidden',         'normal',         'erased',         'A',   'A',   '',    '',  ''],
      ['hidden',         'hidden',         'public',         'A',   'A',   'A',   '',  ''],
      ['hidden',         'hidden',         'requester_only', 'A',   'A',   'A',   '',  ''],
      ['hidden',         'hidden',         'hidden',         'A',   'A',   'A',   '',  ''],
      ['hidden',         'hidden',         'erased',         'A',   'A',   '',    '',  '']
    ].each do |request_state, reply_state, file_state, *who|
      # rubocop:enable Layout/LineLength
      row = columns.zip(who.map { seen(_1) }).to_h

      context "request #{request_state}, reply #{reply_state}, " \
              "file #{file_state}" do
        let(:request) { new_request(request_state) }
        let(:reply) { reply_to(request) }
        let(:file) { file_in(reply, 'runs.txt') }

        before do
          file
          hide(reply, reply_state)
          set_file(file, file_state)
        end

        it 'who sees each part, follows up, and has it in their inbox' do
          expect(cells(request, reply, file)).to eq(row)
        end

        it 'Ability\'s :follow_up and :send_reminder agree with the ' \
           'follow-up form' do
          ability = Ability.new(requester)
          expect(follow_up_actions.map { ability.can?(_1, request) }).
            to eq([follows_up?(ability, request)] * 2)
        end

        it 'every reader agrees with Ability on what the requester sees' do
          got = readers(request, reply, file)
          expect(got.transform_values { agree?(_1) }).
            to eq(request: true, reply: true, file: true)
        end
      end
    end
  end

  describe 'public, requester_only and hidden' do
    include ProminenceHelper

    let(:request) { new_request }
    let(:reply) { reply_to(request) }
    let(:file) { file_in(reply, 'runs.txt') }

    it 'the request page marks a hidden file, not a requester_only or public one' do
      expect(concealed_prominence?(file)).to be(false)
      hide(file, 'public')
      expect(concealed_prominence?(file.reload)).to be(false)
      hide(file, 'hidden')
      expect(concealed_prominence?(file.reload)).to be(true)
    end

    it 'a reply or outgoing message has no requester_only' do
      [reply, request.outgoing_messages.first].each do |message|
        message.prominence = 'requester_only'
        expect(message).not_to be_valid
      end
    end
  end

  describe 'around them' do
    describe 'a spreadsheet not read yet' do
      let(:request) { new_request }
      let(:reply) do
        reply_to(request, 'costs.xlsx',
                 'application/vnd.openxmlformats-officedocument.' \
                 'spreadsheetml.sheet')
      end
      let(:file) { file_in(reply, 'costs.xlsx') }

      it 'is for admins until it is read' do
        expect(Disclosures::SpreadsheetHold.waiting?(file)).to be(true)
        expect(cells(request, reply, file)[:file]).to eq(seen('A'))
      end

      it 'every reader agrees with Ability on what the requester sees' do
        expect(Disclosures::SpreadsheetHold.waiting?(file)).to be(true)
        expect(agree?(readers(request, reply, file)[:file])).to be(true)
        expect(AttachmentManagement::Visibility.describe(file)).
          to eq('Admins only, until it’s been checked.')
      end

      it 'leaves the requester free to delete their request' do
        expect(Disclosures::SpreadsheetHold.waiting?(file)).to be(true)
        deletion = Disclosures::RequestDeletion.new(request.reload, requester)
        expect([deletion.offered?, deletion.blockers]).to eq([true, []])
      end
    end

    describe 'a reply moved to another account\'s request' do
      it 'is theirs, and nothing made from it stays with the first requester' do
        request = new_request
        reply = reply_to(request)
        document = document_from_attachment(file_in(reply, 'runs.txt'),
                                            by: requester)
        destination = FactoryBot.create(:info_request, user: other)
        destination.receive_redelivery(reply, editor: admin)
        reply.destroy
        moved = destination.incoming_messages.last

        expect(IncomingMessage.exists?(reply.id)).to be(false)
        expect(Ability.new(other).can?(:read, moved)).to be(true)
        expect(Ability.new(requester).can?(:read, moved)).to be(false)
        expect(Ability.new(requester).can?(:read, document.reload)).
          to be(false)
        expect(Ability.new(other).can?(:read, document)).to be(false)
      end
    end

    describe 'a request moved to another account' do
      it 'goes with its replies and files to the new account' do
        request = new_request
        reply = reply_to(request)
        file = file_in(reply, 'runs.txt')
        request.move_to_user(other, editor: admin)

        expect(
          %i[request reply file].index_with do |part|
            record = { request: request, reply: reply, file: file }[part]
            [requester, other, admin].map do |user|
              Ability.new(user).can?(:read, record.reload)
            end
          end
        ).to eq(request: [false, true, true], reply: [false, true, true],
                file: [false, true, true])
        expect(IncomingAttention::Effective.
                 relation(IncomingMessage.where(id: reply.id))).to exist
        expect(in_inbox?(other, reply)).to be(true)
        expect(in_inbox?(requester, reply)).to be(false)
      end
    end

    describe 'a published document' do
      it 'is a visitor\'s; its request, reply and file are not' do
        request = new_request
        reply = reply_to(request)
        file = file_in(reply, 'runs.txt')
        document = publish(document_from_attachment(file, by: requester),
                           by: admin)
        visitor = Ability.guest
        expect(
          document: visitor.can?(:read, document.reload),
          request: visitor.can?(:read, request.reload),
          reply: visitor.can?(:read, reply.reload),
          file: visitor.can?(:read, file.reload)
        ).to eq(document: true, request: false, reply: false, file: false)

        hide(request, 'hidden')
        expect(visitor.can?(:read, document.reload)).to be(false)
      end
    end
  end
end
