module Articles
  class Feed
    def initialize(user: nil, number_of_articles: 35, page: 1, tag: nil)
      @user = user
      @number_of_articles = number_of_articles
      @page = page
      @tag = tag
      @randomness = 3 # default number for randomly adjusting feed
      @tag_weight = 1 # default weight tags play in rankings
    end

    def published_articles_by_tag
      articles = Article.published.limited_column_select.page(@page).per(@number_of_articles)
      articles = articles.cached_tagged_with(@tag) if @tag.present? # More efficient than tagged_with
      articles
    end

    # Timeframe values from Timeframer::DATETIMES
    def top_articles_by_timeframe(timeframe:)
      published_articles_by_tag.where("published_at > ?", Timeframer.new(timeframe).datetime).
        order("score DESC").page(@page).per(@number_of_articles)
    end

    def latest_feed
      published_articles_by_tag.order("published_at DESC").
        where("featured_number > ? AND score > ?", 1_449_999_999, -40).
        page(@page).per(@number_of_articles)
    end

    def default_home_feed_and_featured_story(user_signed_in: false, ranking: true)
      featured_story, hot_stories = globally_cached_hot_articles(user_signed_in)
      hot_stories = rank_and_sort_articles(hot_stories) if @user && ranking
      [featured_story, hot_stories]
    end

    # Test variation: Base
    def default_home_feed(user_signed_in: false)
      _featured_story, stories = default_home_feed_and_featured_story(user_signed_in: user_signed_in, ranking: true)
      stories
    end

    # Test variation: More random
    def default_home_feed_with_more_randomness
      @randomness = 7
      _featured_story, stories = default_home_feed_and_featured_story(user_signed_in: true)
      stories
    end

    # Test variation: tags make bigger impact
    def more_tag_weight
      @tag_weight = 2
      _featured_story, stories = default_home_feed_and_featured_story(user_signed_in: true)
      stories
    end

    # Test variation: Base half the time, more random other half. Varies on impressions.
    def mix_default_and_more_random
      if rand(2) == 1
        default_home_feed(user_signed_in: true)
      else
        default_home_feed_with_more_randomness
      end
    end

    def rank_and_sort_articles(articles)
      ranked_articles = articles.each_with_object({}) do |article, result|
        article_points = score_single_article(article)
        result[article] = article_points
      end
      ranked_articles = ranked_articles.sort_by { |_article, article_points| -article_points }.map(&:first)
      ranked_articles.to(@number_of_articles - 1)
    end

    def score_single_article(article)
      article_points = 0
      article_points += score_followed_user(article)
      article_points += score_followed_organization(article)
      article_points += score_followed_tags(article)
      article_points += score_randomness
      article_points += score_language(article)
      article_points += score_experience_level(article)
      article_points
    end

    def score_followed_user(article)
      user_following_users_ids.include?(article.user_id) ? 1 : 0
    end

    def score_followed_tags(article)
      return 0 unless @user

      article_tags = article.decorate.cached_tag_list_array
      user_followed_tags.sum do |tag|
        article_tags.include?(tag.name) ? tag.points * @tag_weight : 0
      end
    end

    def score_followed_organization(article)
      user_following_org_ids.include?(article.organization_id) ? 1 : 0
    end

    def score_randomness
      rand(3) * @randomness
    end

    def score_language(article)
      @user&.preferred_languages_array&.include?(article.language || "en") ? 1 : -15
    end

    def score_experience_level(article)
      - ((article.experience_level_rating - (@user&.experience_level || 5).abs) / 2)
    end

    def globally_cached_hot_articles(user_signed_in)
      # If these query is shared by the all users and fetched often, we can cache it and fetch cold
      # only every x seconds.
      Rails.cache.fetch("globally-cached-hot-articles-#{user_signed_in}", expires_in: 20.seconds) do
        hot_stories = published_articles_by_tag.
          where("score > ? OR featured = ?", 9, true).
          order("hotness_score DESC")
        featured_story = hot_stories.where.not(main_image: nil).first
        if user_signed_in
          offset = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11].sample # random offset, weighted more towards zero
          hot_stories = hot_stories.offset(offset)
          new_stories = Article.published.
            where("published_at > ? AND score > ?", rand(2..6).hours.ago, -15).
            limited_column_select.order("published_at DESC").limit(rand(15..80))
          hot_stories = hot_stories.to_a + new_stories.to_a
        end
        [featured_story, hot_stories.to_a]
      end
    end

    private

    def user_followed_tags
      @user_followed_tags ||= (@user&.decorate&.cached_followed_tags || [])
    end

    def user_following_org_ids
      @user_following_org_ids ||= (@user&.cached_following_organizations_ids || [])
    end

    def user_following_users_ids
      @user_following_users_ids ||= (@user&.cached_following_users_ids || [])
    end
  end
end
