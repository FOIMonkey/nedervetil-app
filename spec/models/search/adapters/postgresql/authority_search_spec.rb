require 'spec_helper'

# The authority typeahead on awkward queries: acronyms, apostrophes, words
# apart, misspellings and visitors in another language.
RSpec.describe Search::Adapters::Postgresql::Adapter, :search_index do
  let(:backend) { described_class.new }

  def body(name, short_name: '', **attributes)
    FactoryBot.create(:public_body, name: name, short_name: short_name,
                                    **attributes)
  end

  def typeahead(query, exclude_tags: %w[defunct not_apply])
    backend.typeahead(query, model: PublicBody, exclude_tags: exclude_tags).
      results(page: 1, per_page: 10).items.map { _1[:model].name }
  end

  it 'puts an authority matching every word first' do
    body('City of Edinburgh Council')
    body('Liverpool City Council')
    body('Liverpool City Region Combined Authority')
    expect(typeahead('Liverpool City Council').first).
      to eq('Liverpool City Council')
  end

  it 'prefers the shorter name when both match every word' do
    body('Lisvane Community Council, Cardiff')
    body('Cardiff Council')
    expect(typeahead('Cardiff Council').first).to eq('Cardiff Council')
  end

  it 'finds an authority by its short name, as for an acronym' do
    body('Department for Work and Pensions', short_name: 'DWP')
    body('Transport for London', short_name: 'TfL')
    body('TfL Trustee Company Limited')
    expect(typeahead('DWP')).to eq(['Department for Work and Pensions'])
    expect(typeahead('TfL').first).to eq('Transport for London')
  end

  it 'matches the last word as a prefix, and drops one under three letters' do
    body('Ministry of Defence')
    expect(typeahead('ministry of def').first).to eq('Ministry of Defence')
    # "de" is dropped, so every ministry matches.
    expect(typeahead('ministry de')).to include('Ministry of Defence')
  end

  it 'ranks the words of a name together over the same words apart' do
    body('King Edward VI Community College Totnes',
         short_name: 'King Edward VI Community College')
    body("King's College London")
    expect(typeahead("King's College").first).to eq("King's College London")
  end

  it 'keeps the words of a name with an apostrophe next to each other' do
    body('Christ The King College, Newport')
    body("King's College London")
    expect(typeahead("King's College").first).to eq("King's College London")
    expect(typeahead('Kings College').first).to eq("King's College London")
  end

  it 'leaves out the tags it is asked to' do
    body('Old Health Authority', tag_string: 'defunct')
    body('Current Health Authority')
    expect(typeahead('Health Authority')).to eq(['Current Health Authority'])
  end

  it 'finds authorities by their notes, rich notes too' do
    coastguard = body('Maritime and Coastguard Agency')
    other = body('Port Authority')
    FactoryBot.create(:note, :for_public_body,
                      notable: other, rich_body: 'Answers for the lighthouses')
    other.reindex
    expect(typeahead('lighthouses')).to eq(['Port Authority'])
    expect(coastguard.reload.notes_for_index).to eq('')
  end

  it 'finds an authority with no translation in the visitor’s language' do
    body('Swansea Council')
    AlaveteliLocalization.with_locale('es') do
      expect(typeahead('Swansea')).to eq(['Swansea Council'])
    end
  end

  it 'offers names like a misspelt query when nothing else matches' do
    body('Liverpool City Council')
    body('Manchester City Council')
    expect(typeahead('Liverpol').first).to eq('Liverpool City Council')
    expect(typeahead('Mancester').first).to eq('Manchester City Council')
  end

  it 'counts exactly, after leaving out the excluded tags' do
    body('NHS England')
    body('NHS Direct', tag_string: 'defunct')
    results = backend.typeahead('NHS', model: PublicBody,
                                       exclude_tags: %w[defunct]).
              results(page: 1, per_page: 10)
    expect(results.total_estimate).to eq(1)
  end

  it 'excludes internal_admin_authority without calling internal_admin_body' do
    internal = body('Internal Admin Body',
                    url_name: 'internal_admin_authority')
    internal.reindex
    body('Internal Audit Agency')
    expect(PublicBody).not_to receive(:internal_admin_body)

    expect(typeahead('Internal')).to eq(['Internal Audit Agency'])
    expect(typeahead('Internl')).to eq(['Internal Audit Agency'])
  end
end
