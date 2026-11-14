require "rails_helper"

RSpec.describe "List statistics", type: :request do
  it "renders without data and signed out" do
    get "/stats/lists"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Mailing lists over time")
  end

  it "survives odd params" do
    get "/stats/lists", params: { lists: "nope", from: "abc", to: "2024-99", gran: "week" }
    expect(response).to have_http_status(:ok)
  end

  context "with data" do
    before do
      build_stats_lists_fixture
      travel_to(Time.utc(2024, 4, 10, 12))
      Stats::Lists::Builder.new.run!
    end

    it "shows tiles, charts and the selection" do
      get "/stats/lists", params: { from: "2024-01", to: "2024-03" }
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.css(".stats-lists-tile .value").first.text).to eq("7")
      kinds = doc.css("[data-release-chart-kind-value]").map { |c| c["data-release-chart-kind-value"] }
      expect(kinds).to eq(%w[stack stack trend trend stack])
      checked = doc.css("input[name='lists[]'][checked]").map { |i| i["value"] }
      expect(checked).to eq(%w[pgsql-hackers pgsql-general])
    end

    it "renders the picker groups and presets" do
      get "/stats/lists", params: { from: "2024-01", to: "2024-03" }
      doc = Nokogiri::HTML(response.body)
      expect(doc.css(".stats-picker-head h2").map(&:text)).to eq(%w[Lists Period Granularity])
      expect(doc.css(".stats-picker-links a").map(&:text)).to include("last year", "3 years", "10 years", "all")
      expect(doc.at_css("input[name=gran][value=week]")["disabled"]).to be_nil
      expect(doc.css(".stats-tab").map(&:text)).to include("Volume")
    end

    it "disables week for ranges over 3 years" do
      get "/stats/lists", params: { from: "2018-01", to: "2024-03" }
      week = Nokogiri::HTML(response.body).at_css("input[name=gran][value=week]")
      expect(week["disabled"]).not_to be_nil
      expect(week.parent["title"]).to be_present
    end

    it "drops the list share for one list" do
      get "/stats/lists", params: { lists: "pgsql-hackers", from: "2024-01", to: "2024-03" }
      expect(response.body).not_to include("Between the lists")
    end
  end

  it "renders newcomers without data" do
    get "/stats/lists/newcomers", params: { lists: "x", gran: "bogus" }
    expect(response).to have_http_status(:ok)
  end

  context "newcomers with data" do
    before do
      build_stats_lists_fixture
      travel_to(Time.utc(2024, 4, 10, 12))
      Stats::Lists::Builder.new.run!
    end

    it "shows tiles, charts, tables" do
      get "/stats/lists/newcomers", params: { from: "2023-10", to: "2024-03" }
      doc = Nokogiri::HTML(response.body)
      expect(doc.css(".stats-lists-tile .value").first.text).to eq("4")
      kinds = doc.css("[data-release-chart-kind-value]").map { |c| c["data-release-chart-kind-value"] }
      expect(kinds.first(3)).to eq(%w[trend trend stack])
      expect(doc.css("table.stats-table").size).to eq(2)
      expect(doc.css(".stats-tab.is-active").text).to eq("Newcomers")
    end
  end

  it "renders regulars without data and with odd params" do
    get "/stats/lists/regulars", params: { score: "bogus", at: "1990-01", lists: "nope" }
    expect(response).to have_http_status(:ok)
  end

  it "renders regulars with hash-valued params" do
    get "/stats/lists/regulars", params: { score: { a: 1 }, at: { a: 1 }, lists: { a: 1 } }
    expect(response).to have_http_status(:ok)
  end

  context "regulars with data" do
    before do
      build_stats_lists_fixture
      travel_to(Time.utc(2024, 4, 10, 12))
      Stats::Lists::Builder.new.run!
    end

    it "shows heatmap, table, bump, concentration" do
      get "/stats/lists/regulars", params: { from: "2024-01", to: "2024-03", score: "messages", at: "2024-01" }
      doc = Nokogiri::HTML(response.body)
      kinds = doc.css("[data-release-chart-kind-value]").map { |c| c["data-release-chart-kind-value"] }
      expect(kinds).to include("heatmap", "bump", "stack")
      expect(doc.css("table.stats-table tbody tr").size).to be >= 4
      expect(doc.css(".stats-seg a.is-active").text).to eq("messages")
    end

    it "is not empty on the 1st before the nightly build" do
      travel_to(Time.utc(2024, 3, 31, 23))
      Stats::Lists::Builder.new.run!
      Rails.cache.clear
      travel_to(Time.utc(2024, 4, 1, 1))
      get "/stats/lists/regulars", params: { score: "messages" }
      doc = Nokogiri::HTML(response.body)
      expect(doc.css("table.stats-table tbody tr").size).to be >= 1
      expect(doc.text).to include("Top 20 in 2024-03")
    end

    it "lists the people who left the top 20 below the bump chart" do
      get "/stats/lists/regulars", params: { from: "2024-01", to: "2024-03", score: "messages" }
      doc = Nokogiri::HTML(response.body)
      bump = JSON.parse(doc.at_css("[data-release-chart-kind-value='bump']")["data-release-chart-data-value"])
      gone = bump["lines"].select { |l| l["values"].last.nil? && l["best"] <= 10 }.map { |l| l["id"].to_s }
      expect(doc.css(".stats-bump-more [data-stats-pin]").map { |b| b["data-stats-pin"] }).to match_array(gone)
      stub_const("Stats::Lists::Regulars::BUMP_TOP", 0)
      Rails.cache.clear
      # Dan is in the December table only, so he has a line but never made the (stubbed) top
      get "/stats/lists/regulars", params: { from: "2023-12", to: "2024-03", score: "messages", at: "2023-12" }
      doc = Nokogiri::HTML(response.body)
      bump = JSON.parse(doc.at_css("[data-release-chart-kind-value='bump']")["data-release-chart-data-value"])
      expect(bump["lines"].map { |l| l["label"] }).to include("Dan")
      expect(doc.css(".stats-bump-more [data-stats-pin]")).to be_empty
    end

    it "steps between months in the table" do
      get "/stats/lists/regulars", params: { from: "2024-01", to: "2024-03", score: "messages", at: "2024-02" }
      doc = Nokogiri::HTML(response.body)
      prev, nxt = doc.css("a.stats-month-step").map { |a| a["href"] }
      expect(prev).to include("at=2024-01").and include("score=messages").and end_with("#top20")
      expect(nxt).to include("at=2024-03")
      get "/stats/lists/regulars", params: { from: "2024-01", to: "2024-03", score: "messages", at: "2024-01" }
      doc = Nokogiri::HTML(response.body)
      expect(doc.css("span.stats-month-step.is-disabled").text).to eq("previous month")
      expect(doc.css("a.stats-month-step").map(&:text)).to eq([ "next month" ])
    end

    it "renders a range after the last built month" do
      StatsRegularsMonthly.where("month > ?", "2024-03-01").delete_all
      get "/stats/lists/regulars", params: { from: "2024-04", to: "2024-04", score: "messages" }
      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).text).to include("Top 20 in 2024-03")
    end

    it "shows the contributor footnote" do
      get "/stats/lists/regulars"
      expect(response.body).to include("from the current contributors list")
    end

    it "keeps score in preset links" do
      get "/stats/lists/regulars", params: { from: "2024-01", to: "2024-03", score: "days" }
      doc = Nokogiri::HTML(response.body)
      hrefs = doc.css(".stats-picker-links a").map { |a| a["href"] }
      expect(hrefs).to all(include("score=days"))
    end
  end
end
