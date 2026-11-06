require "rails_helper"

RSpec.describe Stats::PulseParams do
  it "defaults to weekly, all series" do
    p = described_class.new(params: {})
    expect(p.gran).to eq("week")
    expect(p.group).to eq("all")
  end

  it "accepts the whitelisted values and ignores the rest" do
    p = described_class.new(params: { gran: "month", group: "code" })
    expect(p.gran).to eq("month")
    expect(p.group).to eq("code")
    p = described_class.new(params: { gran: "day", group: "people" })
    expect(p.gran).to eq("week")
    expect(p.group).to eq("all")
  end

  it "knows the strips of each group" do
    expect(described_class::GROUPS["code"]).to eq(%w[commits threads_landing])
    expect(described_class::GROUPS["discussion"]).to eq(%w[messages new_threads patch_submissions active_people first_time_posters])
    expect(described_class.new(params: { group: "all" }).keys).to eq(described_class::ALL_KEYS)
  end
end
