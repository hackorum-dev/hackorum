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

  describe "claims" do
    it "accepts the claimed status and a known mode" do
      run = build(:patchset_run, status: "claimed", mode: PatchsetRun::MODES.first, worker: "box-0", claimed_at: Time.current)
      expect(run).to be_valid
      run.mode = "other"
      expect(run).not_to be_valid
    end

    it "finds stale claims and blocking runs" do
      stale = create(:patchset_run, status: "claimed", claimed_at: 2.hours.ago)
      fresh = create(:patchset_run, status: "claimed", claimed_at: 5.minutes.ago)
      queued = create(:patchset_run, status: "queued")
      done = create(:patchset_run, status: "done")

      expect(PatchsetRun.stale_claims).to eq([ stale ])
      expect(PatchsetRun.claimed).to contain_exactly(stale, fresh)
      expect(PatchsetRun.blocking).to contain_exactly(stale, fresh, done)
      expect(PatchsetRun.blocking).not_to include(queued)
    end
  end

  describe "#finish!" do
    it "keeps a given duration" do
      run = create(:patchset_run, status: "claimed", started_at: 30.seconds.ago, finished_at: nil, duration_s: nil)
      run.finish!(status: "done", duration_s: 12.5)
      expect(run.reload.duration_s).to eq(12.5)
    end

    it "measures from started_at when none is given" do
      run = create(:patchset_run, status: "running", started_at: 90.seconds.ago, finished_at: nil)
      run.finish!(status: "done", story: "x")
      expect(run.status).to eq("done")
      expect(run.duration_s).to be_within(5).of(90)
    end

    it "falls back to started_at for an explicit nil" do
      run = create(:patchset_run, status: "claimed", started_at: 30.seconds.ago, finished_at: nil, duration_s: nil)
      run.finish!(status: "failed", error: "e", duration_s: nil)
      expect(run.reload.duration_s).to be_within(2).of(30)
    end
  end
end
