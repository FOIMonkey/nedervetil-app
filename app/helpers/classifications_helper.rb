# Helpers for classifications
module ClassificationsHelper
  def classification_radio_button(state, id_suffix: nil, current_state: nil)
    id = "#{ state }#{ id_suffix }"
    radio_button 'classification', 'described_state', state,
      id: id, checked: state == current_state
  end

  def classification_label(state, text, id_suffix: nil)
    id = "#{ state }#{ id_suffix }"
    text = tag.i(class: "icon-standalone icon_#{ state }") + tag.span(text)
    label_tag(id, text)
  end
end
