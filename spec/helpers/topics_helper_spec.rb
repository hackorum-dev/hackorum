require "rails_helper"

RSpec.describe TopicsHelper, type: :helper do
  it "labels month ranges" do
    expect(helper.month_range_label(Date.new(2024, 4, 6), Date.new(2024, 5, 26))).to eq("Apr - May 2024")
    expect(helper.month_range_label(Date.new(2026, 6, 30), Date.new(2026, 6, 1))).to eq("Jun 2026")
    expect(helper.month_range_label(Date.new(2025, 12, 14), Date.new(2026, 1, 5))).to eq("Dec 2025 - Jan 2026")
  end

  it "shortens name lists" do
    expect(helper.short_name_list(%w[Korotkov Koval Wang Guo])).to eq("Korotkov, Koval +2")
    expect(helper.short_name_list(%w[Korotkov])).to eq("Korotkov")
  end
end
