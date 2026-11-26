module Admin::AuthorityFeeds
  # Lets an admin match a feed's unmatched authority names to authorities.
  class NamesController < ::AdminController
    SHOWN = 100

    before_action :find_feed

    def index
      @names = ::AuthorityFeeds::Item.
               where(authority_feed_id: @feed.id, public_body_id: nil).
               group(:authority_name).
               order(Arel.sql('COUNT(*) DESC'), :authority_name).
               limit(SHOWN).count
      @aliases = @feed.aliases.includes(:public_body).order(:name).to_a
      @title = "#{@feed.heading}: names to match"
    end

    def create
      body = PublicBody.
             find_by_url_name_with_historic(params[:url_name].to_s.strip)
      if body.nil?
        redirect_to admin_authority_feed_names_path(@feed),
                    flash: { error: 'No authority has that URL name. ' \
                                    'Check it on its page.' }
        return
      end
      ::AuthorityFeeds::NameAlias.find_or_create_by!(
        feed: @feed, name: ::AuthorityFeeds::Matcher.normalise(params[:name])
      ) do |found|
        found.public_body = body
      end
      matched = ::AuthorityFeeds::Decisions.rematch(@feed)
      redirect_to admin_authority_feed_names_path(@feed),
                  notice: "Matched to #{body.name}. #{matched} " \
                          "#{'authority'.pluralize(matched)} updated."
    end

    private

    def find_feed
      @feed = ::AuthorityFeeds::Feed.find(params[:authority_feed_id])
    end
  end
end
