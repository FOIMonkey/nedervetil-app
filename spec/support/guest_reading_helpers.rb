# Text for search and snippets is only what a guest can read, and a guest can
# read no request, so specs of that text let the guest read attachments.
module GuestReadingHelpers
  def allow_guest_to_read_attachments
    ability = Object.new.extend(CanCan::Ability)
    ability.can :read, FoiAttachment
    allow(Ability).to receive(:guest).and_return(ability)
  end
end

RSpec.configure do |config|
  config.include GuestReadingHelpers
end
