require 'spec_helper'

# Some older pages are Foundation nested rows: the page's wrapper pulls its
# sides out by half a gutter and each column pads itself back in. A band is
# not a column, so it reads --nested-row-gutter to step back in itself
# (responsive/_global_layout.scss, features/_band.scss).
RSpec.describe 'A band on a page laid out as a nested row', js: true do
  def left_edges
    page.evaluate_script(<<~JS)
      (() => {
        const content = document.querySelector('#content')
        const inset = parseFloat(getComputedStyle(content).paddingLeft)
        const title = document.querySelector('.page-band h1')
        return {
          title: Math.round(title.getBoundingClientRect().left),
          page: Math.round(content.getBoundingClientRect().left + inset)
        }
      })()
    JS
  end

  it 'starts its title at the page\'s left edge on an authority\'s page' do
    body = FactoryBot.create(:public_body)
    visit "/body/#{body.url_name}"
    expect(page).to have_css('#public_body_show > .page-band h1')
    edges = left_edges
    expect(edges['title']).to eq(edges['page'])
  end

  it 'starts it there on the A to Z list of authorities' do
    visit '/body/list/all'
    expect(page).to have_css('#public_body_list > .page-band h1')
    edges = left_edges
    expect(edges['title']).to eq(edges['page'])
  end

  it 'starts it there on a page that is not a nested row' do
    visit '/topics'
    expect(page).to have_css('.page-band h1')
    edges = left_edges
    expect(edges['title']).to eq(edges['page'])
  end
end
