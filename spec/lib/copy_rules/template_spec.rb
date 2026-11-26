require 'spec_helper'
require 'tempfile'

RSpec.describe CopyRules::Template do
  def template(source)
    described_class.new(source)
  end

  it 'reads literal, translated and contextual visible copy' do
    source = "<p>Plain copy</p><%= _('Oops!') %>" \
             "<%= s_('Greeting|Hello!') %>"
    expect(template(source).text).to include('Plain copy', 'Oops!', 'Hello!')
    expect(template(source).text).not_to include('Greeting|')
  end

  it 'reads both plural forms and interpolated text' do
    # rubocop:disable Lint/InterpolationCheck -- literal ERB source fixture
    source = "<%= n_('One message!', '%{count} messages!', count) %>" \
             '<%= _("Hello #{name}!") %>'
    # rubocop:enable Lint/InterpolationCheck
    expect(template(source).text).
      to include('One message!', '%{count} messages!', 'Hello {{value}}!')
  end

  it 'reads direct and translated link labels' do
    source = "<%= link_to 'Click here', path %>" \
             "<%= link_to(_('Read more'), path) %>"
    expect(template(source).labels('link_to')).
      to eq(['Click here', 'Read more'])
  end

  it 'joins continued strings in translated button labels' do
    source = "<%= form.submit _('Make a new ' \\\n 'request now') %>"
    expect(template(source).labels('submit')).
      to eq(['Make a new request now'])
  end

  it 'reads plural button labels inside a block' do
    source = "<%= form_for record do |form| %>" \
             "<%= form.submit n_('Send one new request', " \
             "'Send all new requests', count) %><% end %>"
    expect(template(source).labels('submit')).
      to eq(['Send one new request', 'Send all new requests'])
  end

  it 'ignores comments and scripts' do
    source = "<%# _('Oops!') %><!-- Oops! -->" \
             "<script><%= _('Oops!') %></script>"
    expect(template(source).text).not_to include('Oops!')
  end
end

RSpec.describe CopyRules do
  def findings(source)
    Tempfile.create(['copy', '.html.erb']) do |file|
      file.write(source)
      file.flush
      described_class.findings(templates: [file.path])
    end
  end

  it 'rejects translated exclamations and cute copy' do
    result = findings("<p><%= _('Oops!') %></p>")
    expect(result[:exclamations]).not_to be_empty
    expect(result[:cute]).not_to be_empty
  end

  it 'rejects vague translated link labels' do
    result = findings("<%= link_to _('Click here'), '/documents' %>")
    expect(result[:vague_links]).not_to be_empty
  end

  it 'counts translated button and link labels' do
    result = findings("<%= button_tag _('Make a new request now') %>" \
                      "<%= link_to _('Find all of the records'), path %>")
    expect(result[:long_buttons]).not_to be_empty
    expect(result[:long_links]).not_to be_empty
  end
end
