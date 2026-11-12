require "rails_helper"

RSpec.describe Api::CursorPaginator do
  let(:user) { create(:user) }
  let(:columns) { %w[api_tokens.created_at api_tokens.id] }

  # 5 tokens, the middle three share a created_at, the last is 1 usec later
  let!(:tokens) do
    base = Time.utc(2026, 1, 1, 12, 0, 0)
    [ 0, 123_456, 123_456, 123_456, 123_457 ].each_with_index.map do |usec, i|
      ApiToken.issue!(user: user, name: "t#{i}").first.tap do |t|
        t.update_columns(created_at: base + Rational(usec, 1_000_000))
      end
    end
  end

  def walk(limit:, direction: :desc)
    seen = []
    cursor = nil
    10.times do
      rows, cursor = described_class.new(ApiToken.all, columns: columns, direction: direction, limit: limit, cursor: cursor).page
      seen.concat(rows)
      return seen if cursor.nil?
    end
    raise "walk did not end"
  end

  it "walks every row once, newest first, through ties" do
    expected = tokens.sort_by { |t| [ t.created_at, t.id ] }.reverse
    expect(walk(limit: 2)).to eq(expected)
  end

  it "walks ascending" do
    expected = tokens.sort_by { |t| [ t.created_at, t.id ] }
    expect(walk(limit: 2, direction: :asc)).to eq(expected)
  end

  it "has no next cursor on an exactly full last page" do
    rows, cursor = described_class.new(ApiToken.all, columns: columns, limit: 5).page
    expect(rows.size).to eq(5)
    expect(cursor).to be_nil
  end

  it "defaults to 50 and clamps to 200" do
    expect(described_class.new(ApiToken.all, columns: columns).limit).to eq(50)
    expect(described_class.new(ApiToken.all, columns: columns, limit: "1000").limit).to eq(200)
  end

  it "rejects bad limits" do
    [ "0", "-1", "abc", "1_0", " 5 ", "+5" ].each do |bad|
      expect { described_class.new(ApiToken.all, columns: columns, limit: bad) }
        .to raise_error(Api::CursorPaginator::InvalidLimit)
    end
  end

  def signature_of(relation, columns, direction: :desc)
    _, cursor = described_class.new(relation, columns: columns, direction: direction, limit: 1).page
    JSON.parse(Base64.urlsafe_decode64(cursor)).first
  end

  it "rejects bad cursors" do
    signature = signature_of(ApiToken.all, columns)
    encoded = ->(values) { Base64.urlsafe_encode64([ signature, *values ].to_json) }
    good = encoded.([ "2026-01-01T12:00:00.123456Z", tokens[2].id ])
    expect(described_class.new(ApiToken.all, columns: columns, cursor: good).page.first).to eq(tokens.first(2).reverse)

    [ "%%%", Base64.urlsafe_encode64("not json"), Base64.urlsafe_encode64("[\"\xff\",1]".b), encoded.([ 1 ]), [ "x" ], { "a" => "b" },
      encoded.([ "abc", 1 ]), encoded.([ nil, nil ]), encoded.([ "2026-01-01T00:00:00Z", 10**30 ]),
      Base64.urlsafe_encode64([ "2026-01-01T00:00:00Z", 1 ].to_json) ].each do |bad|
      expect { described_class.new(ApiToken.all, columns: columns, cursor: bad).page }
        .to raise_error(Api::CursorPaginator::InvalidCursor)
    end

    [ [ 5, 1 ], [ 1.5, 1 ], [ true, 1 ], [ [ 1, 2 ], 1 ], [ { "a" => 1 }, 1 ],
      [ "999999-01-01T00:00:00Z", 1 ], [ "-5000-01-01T00:00:00Z", 1 ],
      [ "2026-01-01T00:00:00Z", "1" ], [ "2026-01-01T00:00:00Z", 1.5 ] ].each do |bad|
      expect { described_class.new(ApiToken.all, columns: columns, cursor: encoded.(bad)).page }
        .to raise_error(Api::CursorPaginator::InvalidCursor), bad.inspect
    end

    by_name = %w[api_tokens.name api_tokens.id]
    name_signature = signature_of(ApiToken.all, by_name)
    named = ->(values) { Base64.urlsafe_encode64([ name_signature, *values ].to_json) }
    expect { described_class.new(ApiToken.all, columns: by_name, cursor: named.([ "t2", 1 ])).page }.not_to raise_error
    [ [ "a\u0000b", 1 ], [ 5, 1 ], [ nil, 1 ], [ [ "a" ], 1 ] ].each do |bad|
      expect { described_class.new(ApiToken.all, columns: by_name, cursor: named.(bad)).page }
        .to raise_error(Api::CursorPaginator::InvalidCursor), bad.inspect
    end

    expect { described_class.new(ApiToken.all, columns: by_name, cursor: Base64.urlsafe_encode64("[\"\xff\",1]".b)).page }
      .to raise_error(Api::CursorPaginator::InvalidCursor)
  end

  describe "a cursor and its ordering" do
    let(:by_use) { %w[api_tokens.last_used_at api_tokens.id] }
    let(:cursor) { described_class.new(ApiToken.all, columns: columns, limit: 2).page.last }

    before { ApiToken.update_all("last_used_at = created_at") }

    it "is taken by the same columns and direction" do
      rows, = described_class.new(ApiToken.where(user: user), columns: columns, direction: "desc", limit: 5, cursor: cursor).page
      expect(rows.size).to eq(3)
    end

    it "is rejected by other columns of the same types" do
      expect { described_class.new(ApiToken.all, columns: by_use, not_null: by_use.first, cursor: cursor).page }
        .to raise_error(Api::CursorPaginator::InvalidCursor)
    end

    it "is rejected by fewer or reordered columns" do
      [ %w[api_tokens.id], %w[api_tokens.created_at api_tokens.token_digest] ].each do |other|
        expect { described_class.new(ApiToken.all, columns: other, cursor: cursor).page }
          .to raise_error(Api::CursorPaginator::InvalidCursor), other.inspect
      end
    end

    it "is rejected by the other direction" do
      expect { described_class.new(ApiToken.all, columns: columns, direction: :asc, cursor: cursor).page }
        .to raise_error(Api::CursorPaginator::InvalidCursor)
    end

    it "is taken with the scope it was made with, and with no other" do
      scoped = described_class.new(ApiToken.all, columns: columns, limit: 2, scope: "list a").page.last

      rows, = described_class.new(ApiToken.all, columns: columns, cursor: scoped, scope: "list a").page
      expect(rows.size).to eq(3)
      [ "list b", nil ].each do |other|
        expect { described_class.new(ApiToken.all, columns: columns, cursor: scoped, scope: other).page }
          .to raise_error(Api::CursorPaginator::InvalidCursor, /another request/), other.inspect
      end
      expect { described_class.new(ApiToken.all, columns: columns, cursor: cursor, scope: "list a").page }
        .to raise_error(Api::CursorPaginator::InvalidCursor)
      expect(Base64.urlsafe_decode64(scoped)).not_to include("list a")
    end

    it "is rejected when it is longer than a cursor can be" do
      expect { described_class.new(ApiToken.all, columns: columns, cursor: cursor + ("A" * 500)).page }
        .to raise_error(Api::CursorPaginator::InvalidCursor)
    end

    it "does not show the column names" do
      expect(Base64.urlsafe_decode64(cursor)).not_to include("api_tokens", "created_at")
    end
  end

  it "walks a date column" do
    days = [ 1, 2, 2, 3 ].map { |d| create(:commitfest, start_date: Date.new(2026, 1, d)) }
    seen = []
    cursor = nil
    4.times do
      rows, cursor = described_class.new(Commitfest.all, columns: %w[commitfests.start_date commitfests.id],
                                         direction: :asc, limit: 1, cursor: cursor).page
      seen.concat(rows)
    end
    expect(cursor).to be_nil
    expect(seen).to eq(days)

    by_date = %w[commitfests.start_date commitfests.id]
    bad = Base64.urlsafe_encode64([ signature_of(Commitfest.all, by_date), "999999-01-01", 1 ].to_json)
    expect { described_class.new(Commitfest.all, columns: by_date, cursor: bad).page }
      .to raise_error(Api::CursorPaginator::InvalidCursor)
  end

  it "keeps the relation's conditions" do
    other = ApiToken.issue!(user: create(:user), name: "other").first
    rows, = described_class.new(ApiToken.where(user: user), columns: columns).page
    expect(rows).not_to include(other)
  end

  describe "not_null:" do
    let(:by_use) { %w[api_tokens.last_used_at api_tokens.id] }

    it "walks a nullable column, leaving NULL rows out" do
      base = Time.utc(2026, 2, 1)
      tokens[0].update_columns(last_used_at: base)
      tokens[2].update_columns(last_used_at: base)
      tokens[4].update_columns(last_used_at: base + 1)

      seen = []
      cursor = nil
      pages = 0
      loop do
        rows, cursor = described_class.new(ApiToken.all, columns: by_use, not_null: [ "api_tokens.last_used_at" ],
                                           limit: 1, cursor: cursor).page
        seen.concat(rows)
        pages += 1
        break if cursor.nil? || pages > 10
      end

      expect(cursor).to be_nil
      expect(seen).to eq([ tokens[4], tokens[2], tokens[0] ])
    end

    it "adds IS NOT NULL to the query" do
      sql = captured_queries do
        described_class.new(ApiToken.all, columns: by_use, not_null: [ "api_tokens.last_used_at" ]).page
      end
      expect(sql.join).to match(/"api_tokens"\."last_used_at" IS NOT NULL/)
    end

    it "still raises without it" do
      expect { described_class.new(ApiToken.all, columns: by_use) }.to raise_error(ArgumentError, /nullable/)
    end

    it "takes only columns of the relation's table" do
      [ "users.created_at", "api_tokens.nope", "last_used_at" ].each do |bad|
        expect { described_class.new(ApiToken.joins(:user), columns: columns, not_null: [ bad ]) }
          .to raise_error(ArgumentError, /#{Regexp.escape(bad)}/)
      end
    end

    it "takes only columns it sorts by" do
      expect { described_class.new(ApiToken.all, columns: columns, not_null: [ "api_tokens.last_used_at" ]) }
        .to raise_error(ArgumentError, /api_tokens\.last_used_at is not a sort column/)
    end

    it "takes nil or a single name" do
      expect { described_class.new(ApiToken.all, columns: columns, not_null: nil) }.not_to raise_error
      rows, = described_class.new(ApiToken.all, columns: by_use, not_null: "api_tokens.last_used_at").page
      expect(rows).to be_empty
    end
  end

  describe "page with a block" do
    it "loads what the block returns and still builds the cursor" do
      given = nil
      rows, cursor = described_class.new(ApiToken.all, columns: columns, limit: 2).page do |relation|
        given = relation
        relation.includes(:user)
      end

      expect(given).to be_a(ActiveRecord::Relation)
      expect(given.limit_value).to eq(3)
      expect(given.order_values).not_to be_empty
      expect(rows.size).to eq(2)
      expect(rows).to all(satisfy { |row| row.association(:user).loaded? })

      expected = tokens.sort_by { |t| [ t.created_at, t.id ] }.reverse
      rest, = described_class.new(ApiToken.all, columns: columns, limit: 2, cursor: cursor).page
      expect(rows + rest).to eq(expected.first(4))
    end

    it "takes a loaded relation with more columns, joins and includes" do
      rows, cursor = described_class.new(ApiToken.all, columns: columns, limit: 2).page do |relation|
        relation.joins(:user).includes(:user)
                .select(ApiToken.arel_table[Arel.star], Arel.sql("users.username AS owner_name")).load
      end

      expect(rows.size).to eq(2)
      expect(cursor).to be_present
      expect(rows).to all(satisfy { |row| row.association(:user).loaded? && row["owner_name"] == user.username })
    end

    it "rejects a block result that is not a relation" do
      paginator = described_class.new(ApiToken.all, columns: columns)

      expect { paginator.page(&:to_a) }.to raise_error(ArgumentError, /relation/)
      expect { paginator.page { nil } }.to raise_error(ArgumentError, /relation/)
    end

    it "rejects a block result with another limit or order" do
      paginator = described_class.new(ApiToken.all, columns: columns)

      expect { paginator.page { |relation| relation.limit(500) } }.to raise_error(ArgumentError, /limit/)
      expect { paginator.page { |relation| relation.unscope(:limit) } }.to raise_error(ArgumentError, /limit/)
      expect { paginator.page { |relation| relation.reorder(:name) } }.to raise_error(ArgumentError, /order/)
      expect { paginator.page { |relation| relation.order(:name) } }.to raise_error(ArgumentError, /order/)
      expect { paginator.page { ApiToken.all } }.to raise_error(ArgumentError)
    end
  end

  it "looks the unique index up once" do
    by_digest = %w[api_tokens.created_at api_tokens.token_digest]
    described_class.new(ApiToken.all, columns: by_digest)

    queries = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }
    described_class.new(ApiToken.all, columns: by_digest)
    ActiveSupport::Notifications.unsubscribe(sub)

    expect(queries).to be_empty
  end

  it "needs a unique last column" do
    [ %w[api_tokens.created_at], %w[api_tokens.id api_tokens.name], %w[api_tokens.created_at api_tokens.user_id] ].each do |bad|
      expect { described_class.new(ApiToken.all, columns: bad) }.to raise_error(ArgumentError, /unique/), bad.inspect
    end

    expect { described_class.new(ApiToken.all, columns: %w[api_tokens.created_at api_tokens.token_digest]) }.not_to raise_error
    expect { described_class.new(ApiToken.all, columns: %w[api_tokens.id]) }.not_to raise_error
  end
end
