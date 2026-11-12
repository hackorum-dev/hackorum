require "rails_helper"

RSpec.describe PruneFeedEventsJob do
  let(:topic) { create(:topic) }

  it "removes only the rows past the retention, in batches, and can run again" do
    stub_const("PruneFeedEventsJob::BATCH", 2)
    old = Array.new(5) { |i| message_event(topic: topic, at: (91 + i).days.ago) }
    edge = message_event(topic: topic, at: Api::EventFeed::RETENTION.ago + 1.minute)
    fresh = message_event(topic: topic)
    allow(Rails.logger).to receive(:info)

    deletes = captured_queries { expect(described_class.new.perform).to eq(5) }.grep(/\ADELETE/)

    expect(deletes.size).to eq(3)
    expect(FeedEvent.order(:id).ids).to eq([ edge.id, fresh.id ])
    expect(FeedEvent.where(id: old.map(&:id))).to be_empty
    expect(Rails.logger).to have_received(:info).with(/pruned 5 feed events/)

    expect(described_class.new.perform).to eq(0)
    expect(FeedEvent.count).to eq(2)
  end

  it "runs daily" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "prune_feed_events")
    expect(entry).to include("class" => "PruneFeedEventsJob")
    expect(entry["schedule"]).to match(/every day at/)
  end
end
