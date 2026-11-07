require "rails_helper"

RSpec.describe StatsHelper, type: :helper do
  describe "#stats_chart" do
    it "emits the controller hook with kind and JSON data" do
      html = helper.stats_chart("spark", { categories: [ "a" ], values: [ 1 ], unit: "x" })
      doc = Nokogiri::HTML.fragment(html).at_css("div")

      expect(doc["data-controller"]).to eq("release-chart")
      expect(doc["data-release-chart-kind-value"]).to eq("spark")
      expect(JSON.parse(doc["data-release-chart-data-value"])).to eq("categories" => [ "a" ], "values" => [ 1 ], "unit" => "x")
      expect(doc["class"]).to eq("stats-chart")
      expect(doc["role"]).to eq("img")
      expect(doc["aria-label"]).to be_nil
    end

    it "labels the chart when asked" do
      html = helper.stats_chart("spark", {}, label: "Commits")
      expect(Nokogiri::HTML.fragment(html).at_css("div")["aria-label"]).to eq("Commits")
    end
  end

  describe "#stats_initials" do
    it "takes the first letter of the first two words that have one" do
      expect(helper.stats_initials("\"Foo\" Bar")).to eq("FB")
      expect(helper.stats_initials("jian he")).to eq("JH")
      expect(helper.stats_initials("- Ann Lee")).to eq("AL")
    end
  end

  describe "#stats_pct" do
    it "rounds to a whole percent and survives a zero denominator" do
      expect(helper.stats_pct(1, 3)).to eq("33%")
      expect(helper.stats_pct(0, 0)).to eq("0%")
    end
  end

  describe "#stats_number" do
    it "delimits thousands" do
      expect(helper.stats_number(2867)).to eq("2,867")
    end
  end

  describe "#stats_period_path" do
    let(:period) { instance_double(Stats::Period::Release, kind: :release, key: "19") }

    it "builds the kind's route for a tab, with extra segments and params" do
      expect(helper.stats_period_path(period)).to eq("/stats/releases/19")
      expect(helper.stats_period_path(period, :pulse, gran: "month")).to eq("/stats/releases/19/pulse?gran=month")
      expect(helper.stats_period_path(period, :person, "a@example.com")).to eq("/stats/releases/19/person/a@example.com")
      expect(helper.stats_period_path(period, :people, format: :csv)).to eq("/stats/releases/19/people.csv")
    end
  end
end
