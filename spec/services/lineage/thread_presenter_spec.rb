require "rails_helper"

RSpec.describe Lineage::ThreadPresenter do
  let(:topic) { create(:topic) }
  let(:run) { create(:patchset_run, topic: topic) }

  it "shows other_thread verdicts, hides not_this_thread" do
    shown = create(:commit_verdict, patchset_run: run, verdict: "other_thread")
    create(:commit_verdict, patchset_run: run, verdict: "not_this_thread")
    expect(described_class.new(topic, ordinals: {}).verdicts.map { |v| v[:sha] }).to eq([ shown.commit.sha ])
  end
end
