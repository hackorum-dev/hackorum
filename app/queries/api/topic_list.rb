module Api
  # Topics for the API list: active topics, optionally searched and filtered.
  class TopicList
    class InvalidQuery < StandardError; end

    MAX_QUERY_LENGTH = 500
    DEFAULT_SORT = "activity".freeze

    SORTS = {
      "activity" => { columns: %w[topics.last_message_at topics.id], not_null: %w[topics.last_message_at] },
      "created" => { columns: %w[topics.created_at topics.id], not_null: [] }
    }.freeze

    attr_reader :relation, :warnings

    def initialize(q: nil, list: nil, author: nil, sort: nil, user: nil)
      @sort = SORTS[sort.presence || DEFAULT_SORT]
      raise InvalidParameter, "sort must be one of: #{SORTS.keys.join(', ')}" unless @sort

      raise InvalidQuery, "query too long, at most #{MAX_QUERY_LENGTH} characters" if q.to_s.length > MAX_QUERY_LENGTH

      @warnings = []
      @user = user
      @query = q.to_s.strip.presence
      relation = Topic.active
      relation = relation.merge(search(@query)) if @query
      relation = without_ignored(relation) if user && !@query
      relation = relation.shown_by_default unless @query || list.present?
      relation = on_list(relation, list) if list.present?
      relation = with_author(relation, author) if author.present?
      @relation = relation
    end

    def columns
      @sort[:columns]
    end

    def not_null
      @sort[:not_null]
    end

    # Run the relation inside: a search value the database cannot take
    # is only found then.
    def run
      yield
    rescue ActiveRecord::RangeError
      raise unless @query
      raise InvalidQuery, "A value in the query is out of range"
    end

    private

    def search(query)
      raise InvalidQuery, "Query has a NUL byte" if query.include?("\0")

      validated = Search::QueryValidator.new(Search::QueryParser.new.parse(query)).validate
      result = Search::QueryBuilder.new(ast: validated.ast, user: @user).build
      @warnings = (validated.warnings + result.warnings).uniq
      result.relation
    rescue Parslet::ParseFailed => e
      raise InvalidQuery, e.message
    end

    # the condition Search::QueryBuilder adds to a search: ignored topics go, starred ones stay
    def without_ignored(relation)
      relation.where(
        "topics.id NOT IN (SELECT topic_id FROM topic_ignores WHERE user_id = ?) " \
        "OR topics.id IN (SELECT topic_id FROM topic_stars WHERE user_id = ?)",
        @user.id, @user.id
      )
    end

    def on_list(relation, identifier)
      list = MailingList.find_by(identifier: identifier) unless identifier.include?("\0")
      raise InvalidParameter, "list is not a mailing list identifier" unless list

      relation.where(id: TopicMailingList.where(mailing_list_id: list.id).select(:topic_id))
    end

    def with_author(relation, email)
      person = Person.find_by_email(email) unless email.include?("\0")
      return relation.none unless person

      relation.where(id: TopicParticipant.where(person_id: person.id).select(:topic_id))
    end
  end
end
