require "rails_helper"

RSpec.describe "Topic#hidden_by_default" do
  let(:hidden_list) { create(:mailing_list, hidden_by_default: true) }
  let(:shown_list) { create(:mailing_list) }

  def post_to(topic, list)
    MessageMailingList.create!(message: create(:message, topic: topic), mailing_list: list)
  end

  it "is false without lists" do
    expect(create(:topic).reload.hidden_by_default).to be(false)
  end

  it "is true when every list is hidden" do
    topic = create(:topic)
    post_to(topic, hidden_list)

    expect(topic.reload.hidden_by_default).to be(true)
    expect(Topic.hidden_by_default).to include(topic)
    expect(Topic.shown_by_default).not_to include(topic)
  end

  it "is false once cross-posted to a shown list" do
    topic = create(:topic)
    post_to(topic, hidden_list)
    post_to(topic, shown_list)

    expect(topic.reload.hidden_by_default).to be(false)
  end

  it "follows the list flag" do
    topic = create(:topic)
    post_to(topic, shown_list)

    shown_list.update!(hidden_by_default: true)
    expect(topic.reload.hidden_by_default).to be(true)

    shown_list.update!(hidden_by_default: false)
    expect(topic.reload.hidden_by_default).to be(false)
  end

  it "is refreshed when a list link goes away" do
    topic = create(:topic)
    post_to(topic, hidden_list)
    post_to(topic, shown_list)

    TopicMailingList.find_by(topic: topic, mailing_list: shown_list).destroy!
    expect(topic.reload.hidden_by_default).to be(true)
  end
end
