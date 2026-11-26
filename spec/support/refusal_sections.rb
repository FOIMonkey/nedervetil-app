# Legislation.refusals is empty unless a theme sets it, as WhatDoTheyKnow's
# does. Specs that need it get the UK Acts' list, and whatever was set before
# is put back.
RSpec.shared_context 'with the UK refusal sections' do
  around do |example|
    previous = Legislation.refusals
    Legislation.refusals = {
      foi: ['s 12', 's 14', *(21..44).map { |n| "s #{n}" }],
      eir: ['reg 12', 'reg 13']
    }
    example.run
  ensure
    Legislation.refusals = previous
  end
end
