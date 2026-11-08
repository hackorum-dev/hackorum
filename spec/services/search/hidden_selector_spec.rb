require "rails_helper"

RSpec.describe "Search hidden: selector", type: :service do
  let(:user) { create(:user, person: create(:person)) }
  let(:parser) { Search::QueryParser.new }
  let!(:hidden_list) { create(:mailing_list, display_name: "committers", hidden_by_default: true) }
  let!(:shown_list) { create(:mailing_list, display_name: "hackers") }

  let!(:hidden_topic) do
    create(:topic, title: "Vacuum notice").tap do |t|
      MessageMailingList.create!(message: create(:message, topic: t), mailing_list: hidden_list)
    end
  end

  let!(:shown_topic) do
    create(:topic, title: "Vacuum discussion").tap do |t|
      MessageMailingList.create!(message: create(:message, topic: t), mailing_list: shown_list)
    end
  end

  def run(query)
    validated = Search::QueryValidator.new(parser.parse(query)).validate
    result = Search::QueryBuilder.new(ast: validated.ast, user: user).build
    [ result.relation.to_a, validated.warnings + result.warnings ]
  end

  it "includes hidden topics by default" do
    topics, = run("title:vacuum")
    expect(topics).to contain_exactly(hidden_topic, shown_topic)
  end

  it "hidden:true includes them" do
    topics, = run("title:vacuum hidden:true")
    expect(topics).to contain_exactly(hidden_topic, shown_topic)
  end

  it "hidden:false excludes them" do
    topics, warnings = run("title:vacuum hidden:false")
    expect(topics).to contain_exactly(shown_topic)
    expect(warnings).to be_empty
  end

  it "negation flips the value" do
    expect(run("title:vacuum -hidden:true").first).to contain_exactly(shown_topic)
    expect(run("title:vacuum -hidden:false").first).to contain_exactly(hidden_topic, shown_topic)
  end

  it "warns on an unknown value" do
    topics, warnings = run("title:vacuum hidden:maybe")
    expect(topics).to contain_exactly(hidden_topic, shown_topic)
    expect(warnings.join).to include("hidden:")
  end

  it "applies to the whole query, not one OR branch" do
    expect(run("title:nothing OR hidden:true").first).to be_empty
    expect(run("(title:vacuum OR title:nothing) hidden:false").first).to contain_exactly(shown_topic)
  end

  it "is ignored with a warning inside a group" do
    topics, warnings = run("-(title:discussion hidden:false)")
    expect(topics).to contain_exactly(hidden_topic)
    expect(warnings.join).to include("hidden:")
  end

  it "works alone" do
    expect(run("hidden:false").first).to contain_exactly(shown_topic)
  end
end
