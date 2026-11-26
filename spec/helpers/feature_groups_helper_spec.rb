require "rails_helper"

RSpec.describe FeatureGroupsHelper, type: :helper do
  def build_version(details)
    FeatureGroupVersion.new(major: 19, status: "shipped", role: "improved",
                            details: { "size" => "moderate", "changes" => 6 }.merge(details))
  end

  it "formats the full line" do
    line = helper.feature_version_line(build_version("lines_added" => 2300, "lines_removed" => 400))
    expect(line).to eq("PostgreSQL 19 · shipped · improved · moderate · 6 commits · +2.3k / -400 lines")
  end

  it "uses the singular" do
    line = helper.feature_version_line(build_version("changes" => 1, "lines_added" => 80, "lines_removed" => 12, "size" => "minor"))
    expect(line).to eq("PostgreSQL 19 · shipped · improved · minor · 1 commit · +80 / -12 lines")
  end

  it "reports unknown lines" do
    expect(helper.feature_version_line(build_version("lines_added" => nil, "lines_removed" => nil)))
      .to eq("PostgreSQL 19 · shipped · improved · moderate · 6 commits · lines unknown")
  end

  it "abbreviates thousands" do
    expect(helper.feature_version_line(build_version("lines_added" => 12400, "lines_removed" => 0)))
      .to include("+12.4k / -0 lines")
    expect(helper.feature_version_line(build_version("lines_added" => 1000, "lines_removed" => 999)))
      .to include("+1k / -999 lines")
  end

  it "skips missing parts" do
    v = FeatureGroupVersion.new(major: 20, status: "worked-on", details: {})
    expect(helper.feature_version_line(v)).to eq("PostgreSQL 20 · worked-on")
  end
end
