require 'spec_helper'
require 'integration/alaveteli_dsl'

# The batch builder with scripts: every search, page, add and remove asks in
# the background and changes only its pane.
RSpec.describe 'Pro batch builder', :search_index, js: true do
  let(:pro_user) { FactoryBot.create(:pro_user) }
  let!(:authorities) { FactoryBot.create_list(:public_body, 26) }

  before do
    with_feature_enabled(:alaveteli_pro)
  end

  def result_names
    all('.batch-builder__search-results .batch-builder__list__item__name').
      map(&:text)
  end

  def chosen
    find('.batch-builder__chosen-authorities')
  end

  def add(body)
    within(".batch-builder__search-results li[data-body-id=\"#{body.id}\"]") do
      click_button 'Add'
    end
  end

  def remove(body)
    within(
      ".batch-builder__chosen-authorities form[data-body-id=\"#{body.id}\"]"
    ) do
      click_button 'Remove'
    end
  end

  it 'searches as you type, pages, adds and removes without leaving the page' do
    using_pro_session(login(pro_user)) do
      visit alaveteli_pro_batch_request_authority_searches_path
      page.execute_script('window.notReloaded = true')
      expect(page).to have_button('Write request', disabled: true)
      expect(page).to have_css('.batch-builder__actions__count',
                               text: '0 of')

      fill_in 'Search for an authority by name', with: 'Example'
      expect(page).to have_css('.batch-builder__search-results ' \
                               '.batch-builder__list__item', count: 25)
      first_page = result_names

      click_link 'Next →'
      expect(page).to have_css('.batch-builder__search-results ' \
                               '.batch-builder__list__item', count: 1)
      expect(first_page).not_to include(result_names.first)

      click_link '← Previous'
      expect(page).to have_css('.batch-builder__search-results ' \
                               '.batch-builder__list__item', count: 25)

      body = PublicBody.find_by(name: result_names.first)
      add(body)
      expect(chosen).to have_text(body.name)
      expect(page).to have_css(
        ".batch-builder__search-results li[data-body-id=\"#{body.id}\"] " \
        'span', text: 'Added', visible: :visible
      )
      expect(page).to have_css('.batch-builder__actions__count',
                               text: '1 of')
      expect(page).to have_button('Write request', disabled: false)

      # The first add made the draft: its id is everywhere now.
      draft = pro_user.draft_info_request_batches.last
      expect(page).to have_current_path(/draft_id=#{draft.id}/)
      expect(find('.batch-builder__actions input[name=draft_id]',
                  visible: :all).value).to eq(draft.id.to_s)

      remove(body)
      expect(chosen).to have_no_text(body.name)
      expect(page).to have_css('.batch-builder__actions__count',
                               text: '0 of')
      expect(page).to have_button('Write request', disabled: true)
      expect(page.evaluate_script('window.notReloaded')).to be true
    end
  end

  it 'says the batch is full until an authority is removed' do
    allow(RequestLimits).to receive(:batch_authority_limit).and_return(2)

    using_pro_session(login(pro_user)) do
      visit alaveteli_pro_batch_request_authority_searches_path
      fill_in 'Search for an authority by name', with: 'Example'
      expect(page).to have_css('.batch-builder__search-results ' \
                               '.batch-builder__list__item', count: 25)
      first, second = result_names.first(2).map do |name|
        PublicBody.find_by(name: name)
      end

      add(first)
      expect(chosen).to have_text(first.name)
      add(second)
      expect(chosen).to have_text(second.name)
      expect(page).to have_css('.batch-builder__search-results .blank-slate',
                               text: 'No more authorities can be added')

      remove(first)
      expect(page).to have_css('.batch-builder__search-results ' \
                               '.batch-builder__list__item', count: 25)
      expect(page).to have_css(
        ".batch-builder__search-results li[data-body-id=\"#{first.id}\"] " \
        'button', text: 'Add', visible: :visible
      )
    end
  end

  context 'browsing by category' do
    let!(:authorities) do
      FactoryBot.create_list(:public_body, 3, tag_string: 'local_council')
    end

    before do
      heading = FactoryBot.create(:category, :public_body,
                                  title: 'Local and regional',
                                  category_tag: 'local_and_regional')
      FactoryBot.create(:category, title: 'Local councils',
                                   category_tag: 'local_council',
                                   parents: [heading])
    end

    it 'opens a heading, then fetches a category’s authorities in place' do
      using_pro_session(login(pro_user)) do
        visit alaveteli_pro_batch_request_authority_searches_path(
          mode: 'browse'
        )
        heading = find('.batch-builder__list__item__anchor[role=button]',
                       text: 'Local and regional')
        expect(heading['aria-expanded']).to eq('false')
        expect(page).to have_no_link('Local councils')

        heading.click
        expect(heading['aria-expanded']).to eq('true')
        click_link 'Local councils'

        authorities.each do |body|
          expect(page).to have_css('.batch-builder__search-results ' \
                                   '.batch-builder__list__item__name',
                                   text: body.name)
        end
        add(authorities.first)
        expect(chosen).to have_text(authorities.first.name)
      end
    end
  end
end
