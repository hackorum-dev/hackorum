require "rails_helper"

RSpec.describe PatchsetRun do
  it "picks the newest done run as current" do
    topic = create(:topic)
    create(:patchset_run, topic: topic, status: "done", created_at: 2.days.ago)
    newest = create(:patchset_run, topic: topic, status: "done", created_at: 1.day.ago)
    create(:patchset_run, topic: topic, status: "failed", created_at: 1.hour.ago)

    expect(described_class.current_for(topic.id)).to eq(newest)
  end

  it "rejects unknown statuses" do
    expect(build(:patchset_run, status: "bogus")).not_to be_valid
  end

  it "finish! stamps duration from started_at" do
    run = create(:patchset_run, status: "running", started_at: 90.seconds.ago, finished_at: nil)
    run.finish!(status: "done", story: "x")
    expect(run.status).to eq("done")
    expect(run.duration_s).to be_within(5).of(90)
  end
end
