require 'spec_helper'

RSpec.describe HelpSite do
  let(:pack) { Rails.root.join('spec/fixtures/help_site').to_s }
  let(:content) { HelpSite::Content.new(pack) }

  describe HelpSite::Content do
    it 'reads the sections in order, with their answers' do
      expect(content.sections.map(&:slug)).to eq(%w[borrowing visiting])
      expect(content.section('borrowing').answers.map(&:id)).
        to eq(%w[how-long renewing])
      expect(content.answers['how-long'].path).to eq('/help/borrowing/how-long')
      expect(content.answers['how-long'].related).to eq(%w[renewing])
    end

    it 'has a page for the front, each section, each answer and the words' do
      expect(content.pages.map(&:path)).to eq(
        %w[/help /help/borrowing /help/visiting /help/borrowing/how-long
           /help/borrowing/renewing /help/visiting/opening-hours /help/words]
      )
    end

    it 'has a guide page only for a pack with a guide' do
      expect(content.guide).to be_nil
      expect(content.page('/help/guide')).to be_nil
    end

    it 'names the view that shows each page' do
      expect(content.pages.map(&:view).uniq).
        to eq(%w[home section answer words])
      page = content.page('/help/borrowing/how-long')
      expect([page.title, page.section.slug, page.answer.id]).
        to eq(['How long can I keep a book?', 'borrowing', 'how-long'])
    end

    it 'has core’s signs, and any the pack adds' do
      expect(content.signs.keys).to include('help', 'words')
    end

    it 'finds a word however it is capitalised' do
      expect(content.meaning('Overdue')).to start_with('Kept past')
      expect(content.meaning('reading room')).to start_with('The quiet room')
      expect(content.meaning('nonesuch')).to be_nil
    end

    it 'gives search only what a reader sees' do
      row = content.search_index.find { _1[:url] == '/help/borrowing/how-long' }
      expect(row).to include(question: 'How long can I keep a book?',
                             section: 'Borrowing books')
      expect(row[:text]).to include('A loan lasts three weeks', 'Reading Room')
      expect(row[:text]).
        not_to match(%r{https?:|/help/|\]\(|To add:|reading room})
    end

    it 'refuses an answer ID used in two sections' do
      Dir.mktmpdir do |dir|
        FileUtils.cp_r("#{pack}/.", dir)
        sections = File.join(dir, 'sections.yml')
        File.write(sections, File.read(sections).sub('- opening-hours',
                                                     '- how-long'))
        FileUtils.cp(File.join(dir, 'answers/borrowing/how-long.md'),
                     File.join(dir, 'answers/visiting/how-long.md'))
        expect { HelpSite::Content.new(dir) }.
          to raise_error(ArgumentError, /how-long is used twice/)
      end
    end

    context 'with no pack' do
      let(:content) { HelpSite::Content.new(nil) }

      it 'has no pages, answers or words, and nothing to search' do
        expect(content.pack?).to be(false)
        expect(content.pages).to eq([])
        expect(content.page('/help')).to be_nil
        expect(content.search_index).to eq([])
      end
    end
  end

  describe HelpSite::Markdown do
    let(:html) do
      described_class.render(content.answers['how-long'].markdown, content)
    end
    let(:doc) { Nokogiri::HTML.fragment(html) }

    it 'links a marked word to its explanation' do
      words = doc.css('a.help-word')
      expect(words.map(&:text)).to eq(['overdue', 'Reading Room'])
      expect(words.map { _1['href'] }).
        to eq(%w[/help/words#overdue /help/words#reading-room])
      expect(words.first['data-means']).to start_with('Kept past')
    end

    it 'marks links out of the site, and leaves links within it alone' do
      expect(doc.at_css('a.help-out')['href']).
        to eq('https://example.org/rules')
      link = doc.css('a').find { _1['href'] == '/help/contact' }
      expect(link['class']).to be_nil
    end

    it 'shows a quote as a note still to be written' do
      expect(doc.at_css('.help-todo').text).
        to include('To add: what happens over the summer.')
    end

    it 'gives words in any script anchors of their own' do
      ids = %w[東京 大阪].map { described_class.word_id(_1) }
      expect(ids).to eq(%w[東京 大阪])
      expect(described_class.word_id('Reading Room')).to eq('reading-room')
      expect(described_class.word_id('Tŷ’r Cyffredin')).to eq('tŷ-r-cyffredin')
    end

    it 'refuses a word the pack does not explain' do
      expect { described_class.render('A [[nonesuch]] word', content) }.
        to raise_error(KeyError)
    end
  end

  describe '.root' do
    after { described_class.reset_root! }

    it 'is the pack of the first loaded theme that has one' do
      Dir.mktmpdir do |dir|
        empty = File.join(dir, 'empty')
        first = File.join(dir, 'first')
        later = File.join(dir, 'later')
        [empty, first, later].each { FileUtils.mkdir_p(_1) }
        [first, later].each { FileUtils.touch(File.join(_1, 'sections.yml')) }
        # The loader requires the themes last to first.
        path = instance_double(Rails::Paths::Path,
                               existent: [later, first, empty])
        allow(Rails.configuration.paths).to receive(:[]).and_call_original
        allow(Rails.configuration.paths).
          to receive(:[]).with('help_site').and_return(path)
        described_class.reload!

        expect(described_class.root).to eq(first)
      end
    end

    it 'is nothing when no theme has a pack' do
      expect(described_class.root).to be_nil
      expect(described_class.pack?).to be(false)
    end

    it 'reads the signs without the rest of the pack' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'sections.yml'), 'groups: [')
        File.write(File.join(dir, 'signs.yml'), 'door: "<path d=\"M1 1\"/>"')
        described_class.root = dir
        expect(described_class.signs.keys).to include('help', 'words', 'door')
      end
    end

    it 'says there is a pack without reading it' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'sections.yml'), 'groups: [')
        described_class.root = dir
        expect(described_class.pack?).to be(true)
        expect { described_class.content }.to raise_error(Psych::SyntaxError)
      end
    end

    it 'can be named outright' do
      described_class.root = pack
      expect(described_class.content.sections.size).to eq(2)
    end
  end
end
