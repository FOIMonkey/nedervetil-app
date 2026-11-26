# A group is a PublicBody category with a tag under the Place, Type or
# Sector heading; its members are the authorities with that tag, as in
# /body/list/<tag>.
module AuthorityGroups
  # Heading category title => [address key, label].
  HEADINGS = { 'Place' => ['place', N_('Places')],
               'Type' => ['type', N_('Types')],
               'Sector' => ['theme', N_('Sectors')] }.freeze
  TAG = /\A[a-z0-9_]+\z/
end
