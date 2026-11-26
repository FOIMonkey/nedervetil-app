require 'forwardable'

# Ordered list returned by PublicBodyCategory.get, mixing heading strings and
# [tag, title, description] arrays, with helpers for tags, headings and lookups.
class PublicBodyCategory::CategoryCollection
  include Enumerable
  extend Forwardable
  def_delegators :@categories, :each, :<<

  def initialize
    @categories = []
  end

  def with_description
    @categories.select { |a| a.instance_of?(Array) }
  end

  def tags
    with_description.map { |a| a[0] }
  end

  def by_tag
    Hash[*with_description.map { |a| a[0..1] }.flatten]
  end

  def headings
    output = []
    @categories.each do |row|
      output << row unless row.is_a?(Array)
    end
    output
  end
end
