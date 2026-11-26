# Use spans so field errors inside paragraphs remain valid HTML.

ActionView::Base.field_error_proc = proc do |html_tag, _instance|
  ActionController::Base.helpers.tag.span(html_tag, class: 'fieldWithErrors')
end
