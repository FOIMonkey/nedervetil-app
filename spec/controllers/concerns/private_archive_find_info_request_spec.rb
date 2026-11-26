require 'spec_helper'

RSpec.describe PrivateArchive, '#find_info_request!' do
  include PrivateArchive

  let(:owner) { FactoryBot.create(:user) }
  let(:stranger) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:viewer) { owner }

  def can?(action, subject)
    Ability.new(viewer).can?(action, subject)
  end

  it 'finds the request by id for a visitor who may do the action' do
    expect(find_info_request!(:read, id: info_request.id)).to eq(info_request)
  end

  it 'finds the request by URL title' do
    expect(find_info_request!(:read, url_title: info_request.url_title)).
      to eq(info_request)
  end

  it 'checks the action asked for, not only reading' do
    expect(find_info_request!(:adjust_deadlines, id: info_request.id)).
      to eq(info_request)
  end

  context 'for someone who may not do the action' do
    let(:viewer) { stranger }

    it 'gives the 404 a stranger gets' do
      expect { find_info_request!(:read, id: info_request.id) }.
        to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  context 'for a signed-out visitor' do
    let(:viewer) { nil }

    it 'gives the 404 a stranger gets' do
      expect { find_info_request!(:read, url_title: info_request.url_title) }.
        to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  it 'gives the same 404 for a request that does not exist' do
    expect { find_info_request!(:read, id: 0) }.
      to raise_error(ActiveRecord::RecordNotFound)
    expect { find_info_request!(:read, url_title: 'no_such_request') }.
      to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'finds nothing for a key that is not a plain value' do
    expect { find_info_request!(:read, id: [info_request.id]) }.
      to raise_error(ActiveRecord::RecordNotFound)
    expect do
      find_info_request!(:read, url_title: { 'x' => info_request.url_title })
    end.to raise_error(ActiveRecord::RecordNotFound)
  end
end
