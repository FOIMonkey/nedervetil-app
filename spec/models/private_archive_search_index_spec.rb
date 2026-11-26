require 'spec_helper'

RSpec.describe 'Searching private requests' do
  def columns(record)
    SearchDocument.where(searchable_type: record.class.name,
                         searchable_id: record.id).
      pick(:raw_content, :raw_admin_content)
  end

  def found(model, query, admin:, **options)
    model.search_scope(query, admin_mode: admin, **options).to_a
  end

  let(:request) do
    FactoryBot.create(:info_request, title: 'Quokka depot inspections',
                                     prominence_reason: 'Quokka admin note')
  end

  it 'gives a request’s title to admin search only' do
    request.reindex
    public_text, admin_text = columns(request)
    expect(public_text.to_s).not_to include('Quokka')
    expect(admin_text).
      to include('Quokka depot inspections', 'Quokka admin note')
    expect(found(InfoRequest, 'Quokka depot', admin: true)).to eq([request])
    expect(found(InfoRequest, 'Quokka depot', admin: false)).to be_empty
  end

  it 'gives the text of its messages to admin search only' do
    message = request.outgoing_messages.first
    message.update!(body: "Dear authority,\n\nPlease send the wallaby rota." \
                          "\n\nYours faithfully,\n\nA Requester")
    message.reindex

    expect(columns(message).first.to_s).not_to include('wallaby')
    expect(found(OutgoingMessage, 'wallaby rota', admin: true)).
      to eq([message])
    expect(found(OutgoingMessage, 'wallaby rota', admin: false)).to be_empty
  end

  it 'keeps them out of public search when the index is rebuilt in bulk' do
    request # made before the rebuild
    InfoRequest.reindex_all
    expect(SearchDocument.where(searchable_type: 'InfoRequest').
             pluck(:raw_content).join).
      not_to include('Quokka')
    expect(found(InfoRequest, 'Quokka depot', admin: true)).to eq([request])
  end

  it 'still indexes an authority publicly' do
    body = FactoryBot.create(:public_body, name: 'Quokka District Council')
    body.reindex
    expect(columns(body).first).to include('Quokka District Council')
  end
end
