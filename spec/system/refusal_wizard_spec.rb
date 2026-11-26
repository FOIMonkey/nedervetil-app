require 'spec_helper'

# Core's help/unhappy omits help/_refusal_advice, so mount a fixture view.
RSpec.describe 'The refusal advice wizard', js: true do
  let(:dir) { Dir.mktmpdir }

  let(:advice) do
    {
      'foi' => {
        'questions' => [
          { 'id' => 'refused',
            'label' => { 'plain' => 'Did they refuse?' },
            'options' => [{ 'value' => 'yes', 'label' => 'Refused' },
                          { 'value' => 'no', 'label' => 'Not refused' }] },
          { 'id' => 'exemption',
            'label' => { 'plain' => 'Which exemptions?' },
            'show_if' => [{ 'id' => 'refused', 'operator' => 'is',
                            'value' => 'yes' }],
            'options' => %w[s12 s14 s21 s40 s43].map do |section|
              { 'value' => section, 'label' => "Section #{section}" }
            end }
        ],
        'actions' => [
          { 'id' => 'review', 'title' => 'Ask for a review',
            'suggestions' => [
              { 'id' => 'cost',
                'advice' => {
                  'plain' => 'Say why it would not cost too much.'
                },
                'show_if' => [{ 'id' => 'exemption', 'operator' => 'is',
                                'value' => 's12' }] }
            ] }
        ]
      }
    }
  end

  before do
    FileUtils.mkdir_p(File.join(dir, 'views/help'))
    File.write(File.join(dir, 'views/help/unhappy.html.erb'),
               "<%= render 'help/refusal_advice' %>\n")
    File.write(File.join(dir, 'advice.yml'), advice.to_yaml)
    ApplicationController.prepend_view_path(File.join(dir, 'views'))
    store = RefusalAdvice::Store.from_yaml([File.join(dir, 'advice.yml')])
    allow(RefusalAdvice).to receive(:default) do |info_request = nil, **options|
      RefusalAdvice.new(store, info_request: info_request, **options)
    end
  end

  after do
    ApplicationController.view_paths =
      ApplicationController.view_paths.paths.reject do |resolver|
        resolver.to_s.start_with?(dir)
      end
    FileUtils.remove_entry(dir)
  end

  it 'asks the next question each answer opens, and suggests advice' do
    visit help_unhappy_path
    first = find('.wizard__question[data-block="refused"]')
    second = find('.wizard__question[data-block="exemption"]', visible: :all)
    expect(first[:class]).to include('wizard__question--answerable')
    expect(second[:class]).not_to include('wizard__question--answerable')

    first.choose('Refused')
    expect(first[:class]).to include('wizard__question--answered')
    expect(second[:class]).to include('wizard__question--answerable')

    expect(page).to have_button('Show more')
    click_button 'Show more'
    expect(second[:class]).to include('expanded')
    expect(page).to have_button('Show less')

    second.check('Section s12')
    expect(page).
      to have_css('.wizard__suggestion--suggested[data-block="cost"]',
                  visible: :all)
    expect(page).
      to have_css('.wizard__next-step--suggested[data-block="review"]')

    first.choose('Not refused')
    expect(second.find('input[value="s12"]', visible: :all)).not_to be_checked
    expect(page).to have_no_css('.wizard__suggestion--suggested', visible: :all)
  end

  it 'opens and shuts a next step from its title' do
    visit help_unhappy_path
    click_link 'Ask for a review'
    expect(page).to have_css('.wizard__action--active', visible: :all)
    click_link 'Ask for a review'
    expect(page).to have_no_css('.wizard__action--active', visible: :all)
  end
end
