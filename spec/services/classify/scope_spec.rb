require "rails_helper"

RSpec.describe Classify::Scope do
  def topic_on_list(list, last_message_at:)
    ml = MailingList.find_by(identifier: list) || create(:mailing_list, identifier: list)
    topic = create(:topic)
    topic.update_columns(last_message_at: last_message_at)
    create(:topic_mailing_list, topic: topic, mailing_list: ml)
    topic
  end

  before { create(:release_tag, name: "REL_16_BETA1", released_at: Time.zone.parse("2024-05-21")) }

  it "keeps active topics on the three lists inside the window" do
    hackers = topic_on_list("pgsql-hackers", last_message_at: 1.month.ago)
    topic_on_list("pgsql-general", last_message_at: 1.month.ago)
    topic_on_list("pgsql-bugs", last_message_at: Time.zone.parse("2023-01-01"))
    merged = topic_on_list("pgsql-docs", last_message_at: 1.month.ago)
    merged.update_columns(merged_into_topic_id: hackers.id)
    expect(described_class.in_window).to contain_exactly(hackers)
    expect(described_class.topics.count).to eq(2)
  end

  it "uses the release tag date as window start" do
    expect(described_class.window_start).to eq(Time.zone.parse("2024-05-21"))
  end
end
