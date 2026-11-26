module Admin::AuthorityFeeds
  # The admin overview of authority page feeds, links and notes.
  class PagesController < ::AdminController
    def index
      @feeds = ::AuthorityFeeds::Feed.ordered.to_a
      @late = @feeds.reject(&:hidden?).select(&:late?)
      @authorities = ::AuthorityFeeds::Summary.
                     where(authority_feed_id: @feeds.map(&:id)).
                     group(:authority_feed_id).count
      @unmatched = ::AuthorityFeeds::Item.
                   where(authority_feed_id: @feeds.map(&:id),
                         public_body_id: nil).
                   group(:authority_feed_id).distinct.count(:authority_name)
      @links = ::AuthorityFeeds::Link.ordered.to_a
      @link_counts = HasTagString::HasTagStringTag.
                     where(model_type: 'PublicBody',
                           name: @links.filter_map(&:tag)).
                     where.not(value: [nil, '']).group(:name).
                     distinct.count(:model_id)
      @notes = Note.where.not(notable_tag: nil).
               or(Note.where(notable_type: 'PublicBody')).
               includes(:notable, translations: :rich_text_rich_body).
               order(:style, :id).to_a
      ActiveRecord::Associations::Preloader.new(
        records: @notes.filter_map(&:notable).grep(PublicBody),
        associations: :translations
      ).call
      @title = 'Authority pages'
    end
  end
end
