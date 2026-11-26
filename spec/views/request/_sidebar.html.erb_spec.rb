require 'spec_helper'

RSpec.describe 'request/sidebar' do
  def render_view
    allow(view).to receive(:current_user).and_return(info_request.user)
    allow(controller).to receive(:current_ability).and_return(ability)

    render partial: self.class.top_level_description,
           locals: stub_locals
  end

  let(:info_request) { FactoryBot.create(:info_request) }
  let(:ability) { Object.new.extend(CanCan::Ability) }

  let(:stub_locals) do
    { info_request: info_request }
  end

  it 'renders the new request CTA' do
    stub_template 'general/_new_request.html.erb' => 'NEW REQUEST CTA'
    render_view
    expect(rendered).to include('NEW REQUEST CTA')
  end

  it 'renders the privacy note' do
    stub_template 'alaveteli_pro/info_requests/_privacy.html.erb' =>
                    'PRIVACY NOTE'
    render_view
    expect(rendered).to include('PRIVACY NOTE')
  end

  it 'shows the request stays private, with no form to change that' do
    render_view
    expect(rendered).
      to have_css('.request-privacy', text: 'This request stays private.')
    expect(rendered).to have_no_css('.request-privacy form')
  end

  context 'when the request is attention_requested' do
    let(:info_request) do
      stubs = { prominence: double.as_null_object,
                attention_requested: true }
      double('InfoRequest', stubs).as_null_object
    end

    it 'renders attention_requested' do
      stub_template 'request/_attention_requested.html.erb' =>
                      'ATTENTION REQUESTED'
      render_view
      expect(rendered).to include('ATTENTION REQUESTED')
    end
  end

  context 'when the request is not attention_requested' do
    let(:info_request) do
      stubs = { prominence: double.as_null_object,
                attention_requested: false }
      double('InfoRequest', stubs).as_null_object
    end

    it 'does not render attention_requested' do
      stub_template 'request/_attention_requested.html.erb' =>
                      'ATTENTION REQUESTED'
      render_view
      expect(rendered).not_to include('ATTENTION REQUESTED')
    end
  end

  it 'renders act links' do
    stub_template 'request/_act.html.erb' => 'ACT LINKS'
    render_view
    expect(rendered).to include('ACT LINKS')
  end

  it 'renders next_actions' do
    stub_template 'request/_next_actions.html.erb' => 'NEXT ACTIONS'
    render_view
    expect(rendered).to include('NEXT ACTIONS')
  end

  it 'renders batch' do
    stub_template 'request/_batch.html.erb' => 'BATCH'
    render_view
    expect(rendered).to include('BATCH')
  end

  it 'renders the copyright notice' do
    render_view
    expect(rendered).to match(/Are you the owner of any commercial copyright/)
  end
end
