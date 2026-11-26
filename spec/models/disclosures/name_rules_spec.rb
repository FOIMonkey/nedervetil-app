require 'spec_helper'

RSpec.describe Disclosures::Checks do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  def account(name, email: 'requester@example.test', earlier: [])
    FactoryBot.build(:user, name: name, email: email).tap do |user|
      allow(user).to receive(:previous_names).and_return(earlier)
    end
  end

  # The kinds of rule that find the account in the text.
  def kinds(user, text)
    even = described_class.even(text)
    described_class.rules_for(user).
      select { |pattern, _what, _kind| even.match?(pattern) }.map(&:last).uniq
  end

  # What each matching rule says the name itself is.
  def names_found(user, text)
    even = described_class.even(text)
    described_class.rules_for(user).filter_map do |pattern, _what, _kind|
      pattern.match(even)&.[](:name)
    end.uniq
  end

  let(:sarah) { account('Sarah Lee') }

  describe 'a first name where the writer is speaking to them' do
    ['Dear Sarah', 'Hello Sarah', 'Hi Sarah', 'Hi, Sarah', 'hi Sarah',
     'DEAR SARAH', 'Hey Sarah', 'Good morning Sarah,', 'Good afternoon Sarah',
     'Good evening Sarah', 'Thank you Sarah for your email',
     'Thanks Sarah, see attached', 'Many thanks Sarah.', 'Thanks, Sarah',
     'Thanks Sarah',
     'Annwyl Sarah', 'Anwyll Sarah', 'Helo Sarah', 'Shwmae Sarah',
     'Shw mae Sarah', 'S’mae Sarah', "S'mae Sarah", 'Bore da Sarah',
     'Prynhawn da Sarah', 'Noswaith dda Sarah', 'Diolch Sarah',
     'Diolch yn fawr Sarah', 'Diolch yn fawr iawn Sarah',
     "Good\nmorning   Sarah"].each do |text|
      it "is found in #{text.inspect}, and the name is the first name alone" do
        expect(kinds(sarah, text)).to eq(['greeting'])
        expect(names_found(sarah, text)).to eq([text[/sarah/i]])
      end
    end
  end

  describe 'a first name on its own' do
    ['Sarah has asked for the gritting records.',
     'Sarah Jones, Information Officer',
     'Sarah, please find the records attached.',
     'This morning Sarah Jones called.', 'Morning Sarah',
     'With thanks Sarah Jones will reply.',
     'dear sarah', 'hi sarah', 'Thanks sarah,'].each do |text|
      it "is not found in #{text.inspect}" do
        expect(kinds(sarah, text)).to be_empty
      end
    end
  end

  describe 'a first name that is also a word' do
    sentences = ['The council will respond within twenty working days.',
                 'This morning will be busy, and good afternoon ' \
                 'sessions may run.',
                 'Our thanks will go to the team; many thanks may be due.',
                 'You may appeal in May 2024.',
                 'Please mark the box, then bill the council.',
                 'We sue for peace and grant funding each year.',
                 'Thank you. Will the council confirm? Hello. Mark the form.',
                 'Hi, may I ask whether the records exist?',
                 'Hello, may I request the following, and hello, will this ' \
                 'be covered?',
                 'Thank you, will you confirm the date? A thank you will be ' \
                 'sent.',
                 'Good morning, will you be in? Good afternoon, mark it as ' \
                 'read.',
                 'We thank you grant funding allowed it. Hi, sue if you ' \
                 'must. Hello, bill us later.']
    %w[Will May Mark Bill Sue Grant].each do |first|
      it "does not find #{first} Lee in ordinary sentences" do
        user = account("#{first} Lee")
        sentences.each do |sentence|
          expect(kinds(user, sentence)).to be_empty, sentence
        end
      end
    end

    it 'still finds them when they are addressed' do
      will = account('Will Lee')
      expect(kinds(will, 'Dear Will')).to eq(['greeting'])
      expect(kinds(will, 'Thanks Will, noted')).to eq(['greeting'])
      expect(kinds(will, 'Thank you, Will, for your email')).
        to eq(['greeting'])
      expect(kinds(account('May Lee'), 'Hi, May')).to eq(['greeting'])
    end

    it 'finds an account that typed its name without capitals as any other' do
      typed = account('sarah lee')
      ['Dear Sarah', 'S Lee', 'Lee, Sarah', 'Ms Lee'].each do |text|
        expect(kinds(typed, text)).not_to be_empty, text
      end
      expect(kinds(typed, 'dear sarah')).to be_empty
    end
  end

  describe 'a short surname' do
    ['S Lee', 'S. Lee', 'S.Lee', 'S LEE', 'Lee, Sarah', 'LEE, SARAH',
     'Lee, S.', "Lee,\nSarah"].each do |text|
      it "is found with an initial or the first name: #{text.inspect}" do
        expect(kinds(sarah, "Signed by #{text} today")).to eq(['name'])
        expect(names_found(sarah, "Signed by #{text} today")).
          to eq([described_class.even(text)])
      end
    end

    ['Ms Lee', 'Mr. Lee', 'Dr Lee'].each do |text|
      it "is found after a title: #{text.inspect}" do
        expect(kinds(sarah, text)).to eq(['title'])
        expect(names_found(sarah, text)).to eq(['Lee'])
      end
    end

    ['the Lee Valley park', 'Slee and Sons', 'SLee Ltd', 's lee', 'S lee',
     'lee, sarah', 'Lee, sarah', 'Lee, Simon', 'Lee Sarah', 'Lee, S',
     'Lee, s.'].each do |text|
      it "is not found on its own or without its capitals: #{text.inspect}" do
        expect(kinds(sarah, text)).to be_empty
      end
    end

    it 'does not take "a day" for A Day or "I may" for I May' do
      expect(kinds(account('Alice Day'), 'within a day of the request')).
        to be_empty
      expect(kinds(account('Ian May'), 'I may be late')).to be_empty
      expect(kinds(account('Alice Day'), 'from A Day, Finance')).
        to eq(['name'])
    end

    it 'does not take them from the capitals the account typed' do
      typed = account('alice day')
      expect(kinds(typed, 'within a day of the request')).to be_empty
      expect(kinds(typed, 'from A Day, Finance')).to eq(['name'])
    end

    it 'does not take "May, I" for the surname and an initial' do
      ian = account('Ian May')
      expect(kinds(ian, 'during April and May, I asked for the records')).
        to be_empty
      expect(kinds(ian, 'listed as May, I. in the file')).to eq(['name'])
      expect(kinds(ian, 'listed as May, Ian in the file')).to eq(['name'])
    end
  end

  describe 'a surname of four letters or more' do
    let(:bob) { account('Bob Smith') }

    it 'is found on its own, so it needs no initial forms' do
      expect(kinds(bob, 'the Smith complaint')).to eq(['surname'])
      expect(kinds(bob, 'B Smith')).to eq(['surname'])
      expect(kinds(bob, 'b smith')).to eq(['surname'])
      expect(described_class.rules_for(bob).size).to eq(6)
    end
  end

  describe 'the account’s name as stored' do
    it 'is looked for without the note a suspended account’s name carries' do
      suspended = FactoryBot.build(:user, :banned, name: 'Sarah Lee')
      allow(suspended).to receive(:previous_names).and_return([])
      expect(suspended.name).not_to eq('Sarah Lee')
      expect(described_class.names_of(suspended)).to eq([%w[Sarah Lee]])
      expect(kinds(suspended, 'Dear Ms Lee')).to eq(['title'])
    end

    it 'is not looked for when it is the placeholder of an erased account' do
      erased = account('[Name Removed]')
      expect(described_class.names_of(erased)).to be_empty
      expect(kinds(erased, 'Dear Name, the Removed file')).to be_empty
    end
  end

  describe 'a name used on earlier messages' do
    let(:renamed) do
      account('Sarah Lee', earlier: ['Dr Sarah Thistlewood', '[Name Removed]',
                                     '', 'Sarah Lee'])
    end

    it 'is looked for as the current name is, without its title' do
      expect(kinds(renamed, 'Dear Mrs Thistlewood')).to include('title')
      expect(kinds(renamed, 'the Thistlewood request')).to eq(['surname'])
      expect(kinds(renamed, 'Sarah Thistlewood')).to include('name')
      expect(kinds(renamed, 'S Lee')).to eq(['name'])
    end

    it 'never looks for the placeholder an erased account leaves' do
      expect(kinds(renamed, 'Dear Name, the Removed file')).to be_empty
      expect(described_class.names_of(renamed)).
        to eq([%w[Sarah Lee], %w[Sarah Thistlewood]])
    end

    it 'is found on a page that holds no other name of theirs' do
      owner = FactoryBot.create(:user, name: 'Sarah Thistlewood')
      request = FactoryBot.create(:info_request, user: owner)
      owner.update!(name: 'Sarah Lee')
      expect(owner.previous_names).to eq(['Sarah Thistlewood'])
      document = delivered_document(
        request, 'letter.pdf', 'application/pdf',
        AttachmentFixtures.pdf(
          pages: [
            AttachmentFixtures.letter_page(secret: 'Dear Mrs Thistlewood')
          ]
        )
      )
      Disclosures::Renderer.new(document).run
      expect(described_class.personal(document).map(&:page).uniq).to eq([1])
    end
  end

  describe Disclosures::EarlierNames do
    def queries
      count = 0
      counter = ->(*, payload) do
        count += 1 unless payload[:cached] || payload[:name] == 'SCHEMA'
      end
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        yield
      end
      count
    end

    # An account that sent a request as before, then changed its name to now.
    def renamed(before, now)
      FactoryBot.create(:user, name: before).tap do |user|
        FactoryBot.create(:info_request, user: user)
        user.update!(name: now)
      end
    end

    it 'looks an account\'s earlier names up once, however often they are asked for' do
      user = renamed('Sarah Thistlewood', 'Sarah Lee')
      expect(queries { 3.times { Disclosures::Checks.rules_for(user) } }).
        to eq(1)
      expect(described_class.of(user)).to eq(['Sarah Thistlewood'])
    end

    it 'looks many accounts up in one query, without their current names' do
      users = [renamed('Sarah Thistlewood', 'Sarah Lee'),
               renamed('Bob Smith', 'Robert Smith'),
               FactoryBot.create(:user, name: 'Never Asked')]
      expect(queries { described_class.load(users) }).to eq(1)
      expect(queries { users.map { |user| described_class.of(user) } }).
        to eq(0)
      expect(users.map { |user| described_class.of(user) }).
        to eq([['Sarah Thistlewood'], ['Bob Smith'], []])
    end
  end

  it 'uses only the kinds the editor script accepts' do
    users = [sarah, account('Bob Smith'), account('Cher'),
             account('Sarah Lee', earlier: ['Sarah Thistlewood'])]
    expect(users.flat_map { |user| described_class.rules_for(user) }.
             map(&:last).uniq - %w[email name surname greeting title]).
      to be_empty
  end

  describe 'Hide my name' do
    before do
      skip 'PDF tools missing' unless AttachmentManagement::Command.
                                      available?('qpdf')
    end

    # Each form on a line of its own, in a PDF with a text layer.
    def pdf_of(lines)
      AttachmentFixtures.pdf(
        pages: [{ texts: lines.each_with_index.map do |line, index|
          { x: 72, y: 780 - (index * 24), text: line, size: 12 }
        end }]
      )
    end

    def text_of(pdf)
      Dir.mktmpdir('name-rules') do |dir|
        path = File.join(dir, 'masked.pdf')
        File.binwrite(path, pdf)
        AttachmentFixtures.pdf_text(path)
      end
    end

    it 'hides every form the check finds, and leaves the greeting or title' do
      user = account('Sarah Lee', earlier: ['Sarah Thistlewood'])
      lines = ['Good morning Sarah, here are the records.',
               'Thanks Sarah, noted.', 'Annwyl Sarah', "S'mae Sarah",
               'Diolch yn fawr Sarah', 'Signed for S. Lee today',
               'Listed as Lee, Sarah in the file', 'Dear Ms Lee',
               'The Thistlewood request', 'A line about the Lee Valley']
      pdf = pdf_of(lines)
      expect(described_class.names?(user, text_of(pdf))).to be true
      masked, = Disclosures::NameMask.redact(pdf, user)
      after = text_of(masked)
      expect(described_class.names?(user, after)).to be(false), after
      expect(after).to include('Good morning', 'Annwyl', 'Diolch yn fawr',
                               'Dear Ms', 'Lee Valley')
      expect(after).not_to include('Sarah', 'Thistlewood')
    end

    it 'leaves an ordinary word that is also the first name' do
      will = account('Will Lee')
      masked, = Disclosures::NameMask.redact(
        pdf_of(['Dear Will', 'Our thanks will go to the team.',
                'The council will respond.', 'Hello, will this be covered?',
                'A thank you will be sent.',
                'With thanks Will Jones will reply.']), will
      )
      after = text_of(masked)
      expect(after).to include('thanks will go', 'council will respond',
                               'Hello, will this', 'thank you will be sent',
                               'thanks Will Jones')
      expect(after).not_to include('Dear Will')
    end
  end
end
