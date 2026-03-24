require "rails_helper"

RSpec.describe "Search list: selector", type: :service do
  let(:person) { create(:person) }
  let(:user) { create(:user, person: person) }
  let(:parser) { Search::QueryParser.new }

  let!(:hackers_list) { create(:mailing_list, identifier: "pgsql-hackers", display_name: "hackers") }
  let!(:bugs_list) { create(:mailing_list, identifier: "pgsql-bugs", display_name: "bugs") }

  let!(:hackers_topic) do
    topic = create(:topic, title: "Hackers Discussion")
    msg = create(:message, topic: topic)
    MessageMailingList.create!(message: msg, mailing_list: hackers_list)
    topic.update_denormalized_counts!
    topic
  end

  let!(:bugs_topic) do
    topic = create(:topic, title: "Bugs Report")
    msg = create(:message, topic: topic)
    MessageMailingList.create!(message: msg, mailing_list: bugs_list)
    topic.update_denormalized_counts!
    topic
  end

  let!(:cross_posted_topic) do
    topic = create(:topic, title: "Cross Posted Thread")
    msg1 = create(:message, topic: topic)
    msg2 = create(:message, topic: topic)
    MessageMailingList.create!(message: msg1, mailing_list: hackers_list)
    MessageMailingList.create!(message: msg2, mailing_list: bugs_list)
    topic.update_denormalized_counts!
    topic
  end

  def build_query(query_string)
    ast = parser.parse(query_string)
    validated = Search::QueryValidator.new(ast).validate
    Search::QueryBuilder.new(ast: validated.ast, user: user).build
  end

  it "filters by list display_name" do
    result = build_query("list:hackers")
    expect(result.relation).to include(hackers_topic, cross_posted_topic)
    expect(result.relation).not_to include(bugs_topic)
  end

  it "filters by a different list" do
    result = build_query("list:bugs")
    expect(result.relation).to include(bugs_topic, cross_posted_topic)
    expect(result.relation).not_to include(hackers_topic)
  end

  it "supports negation" do
    result = build_query("-list:hackers")
    expect(result.relation).to include(bugs_topic)
    expect(result.relation).not_to include(hackers_topic)
  end

  it "supports OR with multiple lists" do
    result = build_query("list:hackers OR list:bugs")
    expect(result.relation).to include(hackers_topic, bugs_topic, cross_posted_topic)
  end

  it "combines with other selectors" do
    result = build_query("list:hackers title:Hackers")
    expect(result.relation).to include(hackers_topic)
    expect(result.relation).not_to include(bugs_topic)
  end
end
