require "rails_helper"

RSpec.describe LineageRecheck do
  it "allows one open recheck per topic and commit" do
    r = create(:lineage_recheck)
    expect { create(:lineage_recheck, topic: r.topic, commit: r.commit) }.to raise_error(ActiveRecord::RecordNotUnique)
    r.update!(done_at: Time.current)
    expect { create(:lineage_recheck, topic: r.topic, commit: r.commit) }.not_to raise_error
  end

  it "scopes open ones" do
    open = create(:lineage_recheck)
    create(:lineage_recheck, done_at: Time.current)
    expect(described_class.open).to eq([ open ])
  end
end
