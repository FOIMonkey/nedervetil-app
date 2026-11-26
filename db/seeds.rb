# This file should contain all the record creation needed to seed the database
# with its default values.
#
# The data can then be loaded with the rails db:seed command (or created
# alongside the database with db:setup).
#
# Examples:
#
#   movies =
#     Movie.create([{ name: 'Star Wars' }, { name: 'Lord of the Rings' }])
#   Character.create(name: 'Luke', movie: movies.first)
#
# IMPORTANT! SEEDS MUST BE IDEMPOTENT. This generally means only creating seeds
# when they don't exist.
Role.create(name: 'admin') if Role.where(name: 'admin').empty?

%w[
  draft complete clarification_needed awaiting_response
  response_received overdue very_overdue other
].each do |category_slug|
  if AlaveteliPro::RequestSummaryCategory.where(slug: category_slug).empty?
    AlaveteliPro::RequestSummaryCategory.create(slug: category_slug)
  end
end
