require "rails_helper"

RSpec.describe Api::TopicList do
  let(:author) { create(:alias, email: "author@example.org") }
  let!(:plain) { create(:topic, title: "Plain thread", creator_alias: author, last_message_at: 3.days.ago) }
  let!(:hidden) { create(:topic, title: "Hidden thread", hidden_by_default: true, last_message_at: 2.days.ago) }
  let!(:merged) { create(:topic, title: "Merged thread", merged_into_topic_id: plain.id, last_message_at: 1.day.ago) }

  it "lists active topics that are shown by default" do
    list = described_class.new

    expect(list.relation).to contain_exactly(plain)
    expect(list.columns).to eq(%w[topics.last_message_at topics.id])
    expect(list.not_null).to eq(%w[topics.last_message_at])
    expect(list.warnings).to eq([])
  end

  it "sorts by creation without a nullable column" do
    list = described_class.new(sort: "created")

    expect(list.columns).to eq(%w[topics.created_at topics.id])
    expect(list.not_null).to eq([])
  end

  it "rejects an unknown sort" do
    expect { described_class.new(sort: "title") }.to raise_error(Api::InvalidParameter, /sort/)
  end

  it "treats a blank q as no search" do
    expect(described_class.new(q: "  ").relation).to contain_exactly(plain)
  end

  it "searches hidden lists too, but never merged topics" do
    expect(described_class.new(q: "title:thread").relation).to contain_exactly(plain, hidden)
    expect(described_class.new(q: "title:thread hidden:false").relation).to contain_exactly(plain)
  end

  it "collects validator and builder warnings" do
    list = described_class.new(q: "title:thread has:nonsense from:me")

    expect(list.warnings).to include(a_string_matching(/has:/), "Must be signed in to use 'me'")
  end

  it "turns parser failures into InvalidQuery" do
    [ "title:\"open", "(a OR", "a" * 2001, "(" * 30 + "a" + ")" * 30, "a\0b" ].each do |q|
      expect { described_class.new(q: q) }.to raise_error(Api::TopicList::InvalidQuery), "for #{q.first(20).inspect}"
    end
  end

  it "filters by mailing list identifier" do
    list = create(:mailing_list, identifier: "pgsql-hackers")
    create(:topic_mailing_list, topic: plain, mailing_list: list)
    create(:topic, last_message_at: 1.day.ago)

    expect(described_class.new(list: "pgsql-hackers").relation).to contain_exactly(plain)
    expect { described_class.new(list: "nope") }.to raise_error(Api::InvalidParameter, /list/)
    expect { described_class.new(list: "a\0b") }.to raise_error(Api::InvalidParameter, /list/)
  end

  it "shows hidden topics of a list that was asked for" do
    list = create(:mailing_list, identifier: "pgsql-hidden", hidden_by_default: true)
    [ hidden, merged ].each { |topic| create(:topic_mailing_list, topic: topic, mailing_list: list) }

    expect(described_class.new(list: "pgsql-hidden").relation).to contain_exactly(hidden)
    expect(described_class.new(list: "pgsql-hidden", q: "title:thread hidden:false").relation).to be_empty
  end

  describe "#run" do
    it "turns a value the database cannot take into InvalidQuery" do
      list = described_class.new(q: "messages:>99999999999999999999")

      expect { list.run { list.relation.to_a } }
        .to raise_error(Api::TopicList::InvalidQuery, /out of range/)
    end

    it "gives the block's value" do
      expect(described_class.new.run { :rows }).to eq(:rows)
    end

    it "leaves a range error alone without a query" do
      expect { described_class.new.run { raise ActiveRecord::RangeError, "elsewhere" } }
        .to raise_error(ActiveRecord::RangeError)
    end
  end

  describe "with a user" do
    let(:user) { create(:user) }
    let!(:ignored) { create(:topic, title: "Ignored thread", last_message_at: 5.days.ago) }
    let!(:kept) { create(:topic, title: "Ignored and starred thread", last_message_at: 4.days.ago) }
    let!(:starred) { create(:topic, title: "Starred thread", last_message_at: 6.days.ago) }

    before do
      [ ignored, kept ].each { |topic| create(:topic_ignore, user: user, topic: topic) }
      [ kept, starred ].each { |topic| create(:topic_star, user: user, topic: topic) }
      other = create(:user)
      create(:topic_ignore, user: other, topic: plain)
      create(:topic_star, user: other, topic: ignored)
    end

    it "leaves out ignored topics that are not starred" do
      expect(described_class.new(user: user).relation).to contain_exactly(plain, kept, starred)
      expect(described_class.new.relation).to contain_exactly(plain, ignored, kept, starred)
    end

    it "filters the plain list as the search builder filters a search" do
      everything = "title:thread hidden:false"
      plain_list = described_class.new(user: user)
      searched = described_class.new(q: everything, user: user)

      expect(described_class.new(q: everything).relation).to match_array(described_class.new.relation)
      expect(plain_list.relation.order(:id).ids).to eq(searched.relation.order(:id).ids)
      expect(searched.relation).to contain_exactly(plain, kept, starred)

      builder = Search::QueryBuilder.new(ast: Search::QueryParser.new.parse("title:thread"), user: user).build
      condition = builder.relation.to_sql[/topics\.id NOT IN .*\z/]
      expect(condition).to be_present
      expect(plain_list.relation.to_sql).to include(condition)
    end

    it "keeps the filter with list and author, and drops it for an ignored: selector" do
      list = create(:mailing_list, identifier: "pgsql-hackers")
      [ plain, ignored, kept ].each do |topic|
        create(:topic_mailing_list, topic: topic, mailing_list: list)
        TopicParticipant.create!(topic: topic, person: author.person, message_count: 1,
                                 first_message_at: 1.day.ago, last_message_at: 1.day.ago)
      end

      expect(described_class.new(list: "pgsql-hackers", user: user).relation).to contain_exactly(plain, kept)
      expect(described_class.new(author: "author@example.org", user: user).relation).to contain_exactly(plain, kept)
      expect(described_class.new(q: "ignored:me", user: user).relation).to contain_exactly(ignored, kept)
      expect(described_class.new(q: "title:thread -ignored:me", user: user).relation)
        .to contain_exactly(plain, hidden, starred)
    end

    it "searches as the user" do
      list = described_class.new(q: "starred:me", user: user)

      expect(list.relation).to contain_exactly(kept, starred)
      expect(list.warnings).to eq([])
    end
  end

  it "filters by a participant's email" do
    other = create(:topic, last_message_at: 1.day.ago)
    TopicParticipant.create!(topic: other, person: author.person, message_count: 1,
                             first_message_at: 1.day.ago, last_message_at: 1.day.ago)

    expect(described_class.new(author: "AUTHOR@example.org").relation).to contain_exactly(other)
    expect(described_class.new(author: "nobody@example.org").relation).to be_empty
    expect(described_class.new(author: "a\0b").relation).to be_empty
  end
end
