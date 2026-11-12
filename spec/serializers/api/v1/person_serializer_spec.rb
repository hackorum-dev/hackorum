require "rails_helper"

RSpec.describe Api::V1::PersonSerializer do
  let(:context) { Api::V1::Context.new(user: nil, token: nil, base_url: "https://hackorum.example") }
  let(:person) { create(:person) }

  def with_default_alias(person, name:, email:)
    al = create(:alias, person: person, name: name, email: email)
    person.update!(default_alias_id: al.id)
    person
  end

  it "gives the brief shape" do
    with_default_alias(person, name: "Alice A", email: "alice+pg@example.com")

    expect(described_class.new(person, context).brief).to eq(
      id: person.id,
      name: "Alice A",
      email: "alice+pg@example.com",
      url: "https://hackorum.example/api/v1/people/alice%2Bpg%40example.com",
      html_url: "https://hackorum.example#{context.routes.person_path('alice+pg@example.com')}"
    )
  end

  it "has no links without an alias" do
    brief = described_class.new(person, context).brief

    expect(brief).to eq(id: person.id, name: "Unknown", email: nil, url: nil, html_url: nil)
  end

  describe "without a default alias" do
    def without_default(person)
      person.update_columns(default_alias_id: nil)
      Person.preload(described_class::PRELOAD).find(person.id)
    end

    it "takes the sending alias with the lowest email" do
      create(:alias, person: person, name: "Mentioned", email: "a@example.com", created_at: 3.years.ago)
      create(:alias, :with_sent_messages, person: person, name: "Zed", email: "z@example.com", created_at: 2.years.ago)
      create(:alias, :with_sent_messages, person: person, name: "Bee", email: "b@example.com")

      expect(described_class.new(without_default(person), context).brief).to eq(
        id: person.id,
        name: "Bee",
        email: "b@example.com",
        url: "https://hackorum.example/api/v1/people/b%40example.com",
        html_url: "https://hackorum.example#{context.routes.person_path('b@example.com')}"
      )
    end

    it "takes the oldest alias when none has sent mail" do
      create(:alias, person: person, name: "Newer", email: "a@example.com")
      create(:alias, person: person, name: "Older", email: "o@example.com", created_at: 2.years.ago)

      brief = described_class.new(without_default(person), context).brief

      expect(brief).to include(name: "Older", email: "o@example.com")
      expect(brief[:url]).to end_with("/people/o%40example.com")
    end

    it "runs no query on preloaded people" do
      create(:alias, :with_sent_messages, person: person, email: "b@example.com")
      loaded = without_default(person)

      expect(captured_queries { described_class.new(loaded, context).brief }).to be_empty
    end
  end

  it "serializes a list" do
    other = with_default_alias(create(:person), name: "Bob", email: "bob@example.com")

    list = described_class.brief_list([ person, other ], context)

    expect(list.map { |row| row[:id] }).to eq([ person.id, other.id ])
    expect(list.last[:email]).to eq("bob@example.com")
  end
end

RSpec.describe Api::V1::BaseSerializer do
  let(:context) { Api::V1::Context.new(user: nil, token: nil, base_url: "https://hackorum.example") }
  let(:klass) do
    Class.new(described_class) do
      def brief = { id: record, url: api_url("/things/#{record}") }
      def full = brief.merge(html_url: site_url("/things/#{record}"))
    end
  end

  it "gives the full shape only when asked" do
    expect(klass.new(7, context).full).to eq(
      id: 7, url: "https://hackorum.example/api/v1/things/7", html_url: "https://hackorum.example/things/7"
    )
    expect(described_class.method_defined?(:as_json, false)).to be(false)
  end

  it "falls back to brief for full" do
    plain = Class.new(described_class) { def brief = { id: record } }

    expect(plain.new(7, context).full).to eq(id: 7)
  end

  it "maps lists" do
    expect(klass.brief_list([ 1, 2 ], context).map { |row| row[:id] }).to eq([ 1, 2 ])
  end

  it "hands extras to every row" do
    tagged = Class.new(described_class) { def brief = { id: record, tag: extras[:tag] } }

    expect(tagged.new(1, context).extras).to eq({})
    expect(tagged.new(1, context, tag: "x").brief).to eq(id: 1, tag: "x")
    expect(tagged.brief_list([ 1, 2 ], context, tag: "x")).to eq([ { id: 1, tag: "x" }, { id: 2, tag: "x" } ])
  end
end
