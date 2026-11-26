require 'spec_helper'
require 'integration/alaveteli_dsl'

# Uses CDP mouse events because SortableJS listens to pointer events.
RSpec.describe 'Dragging categories into order', js: true do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:root) { PublicBody.category_root }

  let!(:headings) do
    %w[Alpha Bravo Charlie Delta Echo].map do |name|
      FactoryBot.create(:category, :public_body,
                        title: "Heading #{name}",
                        category_tag: "h_#{name.downcase}")
    end
  end

  let!(:children) do
    %w[One Two Three Four Five].map do |name|
      FactoryBot.create(:category, parents: [headings.first],
                                   title: "Child #{name}",
                                   category_tag: "c_#{name.downcase}")
    end
  end

  def mouse
    page.driver.browser.mouse
  end

  def centre(element)
    rect = page.evaluate_script(<<~JS, element)
      (function (el) {
        el.scrollIntoView({ block: 'center' })
        const r = el.getBoundingClientRect()
        return [r.left + r.width / 2, r.top + r.height / 2, r.top, r.bottom]
      })(arguments[0])
    JS
    rect
  end

  def drag(item, onto:, place:)
    handle = item.find('.category-drag-handle', match: :first)
    x, y = centre(handle)
    target_box = page.evaluate_script(<<~JS, onto)
      (function (el) {
        const r = el.getBoundingClientRect()
        return [r.top, r.bottom]
      })(arguments[0])
    JS
    to_y = place == :before ? target_box[0] + 3 : target_box[1] - 3
    mouse.move(x: x, y: y)
    mouse.down
    # At a hand's pace: Sortable looks at the pointer every 50ms while
    # dragging, so a sweep faster than that skips rows no hand would.
    steps = 30
    (1..steps).each do |step|
      mouse.move(x: x, y: y + ((to_y - y) * step / steps.to_f))
      sleep 0.04
    end
    # Hold at the drop point, as a hand does, so a busy machine's browser
    # still sees the pointer there before the release.
    4.times do |nudge|
      sleep 0.08
      mouse.move(x: x + (nudge.even? ? 1 : 0), y: to_y)
    end
    sleep 0.2
    mouse.up
    sleep 0.3
  end

  def heading_titles
    all('#category_list > .admin-category-group .item-title strong').
      map(&:text) & headings.map(&:title)
  end

  def child_titles
    all("#heading_#{headings.first.id}_category_list > .category-list-item").
      map { |el| el.text.strip } & children.map(&:title)
  end

  def heading_item(title)
    find('#category_list > .admin-category-group', text: title, match: :first)
  end

  def child_item(title)
    find("#heading_#{headings.first.id}_category_list > .category-list-item",
         text: title)
  end

  def saved_heading_titles
    root.reload.children.map(&:title) & headings.map(&:title)
  end

  def saved_child_titles
    headings.first.reload.children.map(&:title) & children.map(&:title)
  end

  before { login_as_admin }

  def login_as_admin
    admin.update!(otp_secret: User.generate_otp_secret,
                  otp_required_for_login: true)
    visit signin_path
    within '#signin_form' do
      fill_in 'user_signin_email', with: admin.email
      fill_in 'user_signin_password', with: 'jonespassword'
      fill_in 'user_signin_otp_attempt', with: admin.current_otp
      click_button(name: 'commit')
    end
    expect(page).to have_no_css('#signin_form')
  end

  def heading_panel
    find_by_id('category_list').sibling('.save-panel')
  end

  describe 'headings' do
    before { visit admin_categories_path(model_type: 'PublicBody') }

    it 'moves the first to the end, selecting no text on the way' do
      first = heading_titles.first
      last = heading_titles.last
      drag(heading_item(first), onto: heading_item(last), place: :after)
      expect(heading_titles.last).to eq(first)
      expect(page.evaluate_script('window.getSelection().toString()')).to eq('')
      expect(page).to have_no_css('body.category-sorting')
      expect(heading_panel).to have_text('There are unsaved changes')
    end

    it 'moves the last to the start' do
      first = heading_titles.first
      last = heading_titles.last
      drag(heading_item(last), onto: heading_item(first), place: :before)
      expect(heading_titles.first).to eq(last)
    end

    it 'moves one down past several, then saves the order for a reload' do
      before = heading_titles
      drag(heading_item(before[1]),
           onto: heading_item(before[3]), place: :after)
      expected = before.dup.tap { |list| list.insert(3, list.delete_at(1)) }
      expect(heading_titles).to eq(expected)

      heading_panel.click_link('Save')
      expect(heading_panel).to have_text('Changes saved.')
      visit admin_categories_path(model_type: 'PublicBody')
      expect(heading_titles).to eq(expected)
      expect(saved_heading_titles).to eq(expected)
    end

    it 'moves one up past several' do
      before = heading_titles
      drag(heading_item(before[3]),
           onto: heading_item(before[0]), place: :before)
      expected = before.dup.tap { |list| list.insert(0, list.delete_at(3)) }
      expect(heading_titles).to eq(expected)
    end

    it 'moves a heading while another is open, leaving its categories inside it' do
      heading_item(headings.first.title).
        find('.admin-category-group__details > summary').click
      expect(page).to have_css(
        ".admin-category-group__details[open] " \
        "#heading_#{headings.first.id}_categories"
      )
      before = heading_titles
      drag(heading_item(before.last),
           onto: heading_item(before.first), place: :before)
      expect(heading_titles.first).to eq(before.last)
      expect(child_titles).to eq(children.map(&:title))
    end
  end

  describe 'categories under a heading' do
    let(:child_panel) do
      find("#heading_#{headings.first.id}_category_list").sibling('.save-panel')
    end

    before do
      visit admin_categories_path(model_type: 'PublicBody')
      heading_item(headings.first.title).
        find('.admin-category-group__details > summary').click
      expect(page).to have_css(
        ".admin-category-group__details[open] " \
        "#heading_#{headings.first.id}_categories"
      )
    end

    it 'moves the first to the end and the last to the start' do
      titles = child_titles
      drag(child_item(titles.first),
           onto: child_item(titles.last), place: :after)
      expect(child_titles.last).to eq(titles.first)

      titles = child_titles
      drag(child_item(titles.last),
           onto: child_item(titles.first), place: :before)
      expect(child_titles.first).to eq(titles.last)
    end

    it 'moves one across several both ways, saves, and keeps the order after a reload' do
      titles = child_titles
      drag(child_item(titles[0]), onto: child_item(titles[3]), place: :after)
      titles = titles.dup.tap { |list| list.insert(3, list.delete_at(0)) }
      expect(child_titles).to eq(titles)

      drag(child_item(titles[4]), onto: child_item(titles[1]), place: :before)
      titles = titles.dup.tap { |list| list.insert(1, list.delete_at(4)) }
      expect(child_titles).to eq(titles)

      expect(heading_titles).to eq(headings.map(&:title) & heading_titles)
      expect(heading_panel).to have_text('Drag and drop to change the order')

      child_panel.click_link('Save')
      expect(child_panel).to have_text('Changes saved.')
      visit admin_categories_path(model_type: 'PublicBody')
      expect(saved_child_titles).to eq(titles)
      heading_item(headings.first.title).
        find('.admin-category-group__details > summary').click
      expect(child_titles).to eq(titles)
    end
  end
end
