require "rails_helper"

RSpec.describe "Release statistics", type: :request do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }
  let(:user) { create(:user) }

  before { travel_to(now) }

  def enable_feature
    UserFeature.create!(user: user, feature: "patchset_lineage")
  end

  it "redirects signed-out visitors to sign in" do
    get "/stats"
    expect(response).to redirect_to(new_session_path)
  end

  it "hides the tree without the feature" do
    sign_in_as(user)
    get "/stats"
    expect(response).to have_http_status(:not_found)
    get "/stats/releases/19"
    expect(response).to have_http_status(:not_found)
    get "/stats/releases/19/pulse"
    expect(response).to have_http_status(:not_found)
    get "/stats/releases/19/people"
    expect(response).to have_http_status(:not_found)
    get "/stats/releases/19/companies"
    expect(response).to have_http_status(:not_found)
    get "/stats/releases/19/committers"
    expect(response).to have_http_status(:not_found)
    get "/stats/releases/19/person/alice@example.com"
    expect(response).to have_http_status(:not_found)
    get "/stats/trends/years"
    expect(response).to have_http_status(:not_found)
    get "/stats/years/2026"
    expect(response).to have_http_status(:not_found)
    get "/stats/cycles/2025"
    expect(response).to have_http_status(:not_found)
    get topics_path
    expect(response.body).not_to include('href="/stats"')
  end

  context "with the feature" do
    before do
      enable_feature
      sign_in_as(user)
    end

    it "lists the statistics and links the nav" do
      get "/stats"
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      cards = doc.css("a.stats-card")
      expect(cards.map { |c| c.at_css("h2").text }).to eq([ "By release", "By year", "By development cycle",
                                                             "Release over release", "Year over year", "Cycle over cycle" ])
      expect(cards.map { |c| c["href"] }).to eq([ "/stats/releases/19", "/stats/years/2026", "/stats/cycles/2026",
                                                  "/stats/trends/releases", "/stats/trends/years", "/stats/trends/cycles" ])
      expect(cards.map { |c| c.at_css("img.stats-card-art")["src"] }).to all(match(%r{/assets/stats/(release|year|cycle)(-trend)?-\w+\.png}))
      expect(response.body).not_to include("PG19 and how")
      expect(response.body).to include("counted from the previous GA to its own GA")
      expect(response.body).to include("January to December")
      expect(response.body).to include("from the day the previous major branched off")
      get topics_path
      expect(response.body).to include('href="/stats"')
    end

    it "renders the overview with release chips and tabs" do
      get "/stats/releases/19"
      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("PG19")
      expect(body).to include('class="stats-chip is-active"')
      expect(body).to include("PG20")
      expect(body).to include("in development")
      expect(body).to include('class="stats-tab is-active"')
    end

    it "renders every band with chart data" do
      get "/stats/releases/19"
      doc = Nokogiri::HTML(response.body)
      %w[Code Discussion Patch\ lineage Reviews Who\ shaped\ PG19].each do |band|
        expect(doc.css(".stats-band").map(&:text).join).to include(band)
      end
      charts = doc.css("[data-controller='release-chart']")
      expect(charts.size).to be >= 9
      charts.each do |chart|
        data = JSON.parse(chart["data-release-chart-data-value"])
        case chart["data-release-chart-kind-value"]
        when "spark", "bars" then expect(data.keys).to include("categories", "values", "unit")
        when "share" then expect(data["segments"]).to all(include("label", "value"))
        when "histogram" then expect(data.keys).to include("categories", "series")
        else raise "unknown kind #{chart['data-release-chart-kind-value']}"
        end
      end
      commits = doc.css(".stats-tile").find { |t| t.at_css(".k")&.text == "Commits" }
      expect(commits.at_css(".v").text).to eq("4")
      expect(response.body).to include("Also backported")
      expect(response.body).to include("Commits with a Commitfest entry")
      expect(response.body).to include(person_path("alice@example.com"))
      expect(response.body).to include("Of all commits, written by someone other than the committer")
      expect(response.body).to include("1 of 3, 1 credits")
      hists = charts.select { |c| c["data-release-chart-kind-value"] == "histogram" }.map { |c| JSON.parse(c["data-release-chart-data-value"]) }
      expect(hists.map { |h| h["labels"] }).to contain_exactly(false, nil)
    end

    it "marks LLM tiles as not available without verdicts" do
      CommitVerdict.delete_all
      Rails.cache.clear
      get "/stats/releases/19"
      expect(response.body).to include("not available")
      na = Nokogiri::HTML(response.body).css(".stats-tile.is-na")
      expect(na.size).to eq(7)
      expect(na.map(&:text)).to all(include("not available"))
      na.each { |tile| expect(tile.css("[data-controller='release-chart']")).to be_empty }
    end

    it "hides LLM numbers when the verdicts cover too few commits" do
      CommitVerdict.where(commit: fx.commits[:c4]).delete_all
      Rails.cache.clear
      get "/stats/releases/19"
      expect(response.body).to include("not shown: the LLM covers only 50% of commits")
      expect(Nokogiri::HTML(response.body).css(".stats-tile.is-na").size).to eq(7)

      get "/stats/releases/19/committers"
      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-release-chart-kind-value='ranked']").size).to eq(2)
      expect(doc.css("thead th").map(&:text)).not_to include("As posted")
      get "/stats/releases/19/committers.csv"
      expect(response.body.lines.first.chomp).not_to include("as_posted")

      get "/stats/releases/19/person/alice@example.com"
      expect(response.body).not_to include("Patches they committed for others")
      expect(response.body).not_to include("Versions per patch")
      expect(response.body).not_to include("Sole reviewer")
    end

    it "keeps companies out of releases before PG19" do
      create(:release_tag, name: "REL_17_BETA1", released_at: Time.zone.parse("2024-05-21"))
      get "/stats/releases/18"
      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).css(".stats-tab").map(&:text)).not_to include("Companies")
      get "/stats/releases/18/companies"
      expect(response).to have_http_status(:not_found)
      get "/stats/releases/18/people"
      expect(Nokogiri::HTML(response.body).css("thead th").map(&:text)).not_to include("Company")
      get "/stats/releases/18/people.csv"
      expect(response.body.lines.first).to start_with("rank,name,credits")
      get "/stats/releases/19/people"
      expect(Nokogiri::HTML(response.body).css("thead th").map(&:text)).to include("Company")
    end

    it "marks the line tiles as not available without line counts" do
      Commit.update_all(lines_added: nil, lines_removed: nil)
      Rails.cache.clear
      get "/stats/releases/19"
      doc = Nokogiri::HTML(response.body)
      lines = doc.css(".stats-tile").find { |t| t.at_css(".k")&.text == "Lines" }
      hist = doc.at_css(".stats-tile.is-hist")
      [ lines, hist ].each do |tile|
        expect(tile["class"]).to include("is-na")
        expect(tile.text).to include("not available")
        expect(tile.css("[data-controller='release-chart']")).to be_empty
      end
    end

    it "renders the pulse tab with controls and the strips chart" do
      get "/stats/releases/19/pulse"
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css(".stats-tab.is-active").text).to eq("Pulse")
      expect(doc.at_css("a.stats-tab[href='/stats/releases/19']").text).to eq("Overview")
      chart = doc.at_css("[data-controller='release-chart'][data-release-chart-kind-value='strips']")
      data = JSON.parse(chart["data-release-chart-data-value"])
      expect(data.keys).to include("gran", "buckets", "windows", "bands", "events", "strips")
      expect(data["strips"].map { |s| s["key"] }).to eq(Stats::PulseParams::ALL_KEYS)
      expect(data["gran"]).to eq("week")
      expect(doc.css(".stats-seg-item[aria-current='page']").map(&:text)).to eq(%w[Week All])
      expect(response.body).to include("/stats/releases/19/pulse?gran=month&amp;group=all")
      expect(response.body).to include("/stats/releases/19/pulse?gran=week&amp;group=code")
    end

    it "filters strips by group and falls back on junk params" do
      get "/stats/releases/19/pulse", params: { gran: "month", group: "code" }
      data = JSON.parse(Nokogiri::HTML(response.body).at_css("[data-release-chart-kind-value='strips']")["data-release-chart-data-value"])
      expect(data["gran"]).to eq("month")
      expect(data["strips"].map { |s| s["key"] }).to eq(%w[commits threads_landing])

      get "/stats/releases/19/pulse", params: { gran: "day", group: "nope" }
      data = JSON.parse(Nokogiri::HTML(response.body).at_css("[data-release-chart-kind-value='strips']")["data-release-chart-data-value"])
      expect(data["gran"]).to eq("week")
      expect(data["strips"].size).to eq(7)
    end

    it "renders the people tab, sorts, filters and exports" do
      get "/stats/releases/19/people"
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css(".stats-tab.is-active").text).to eq("People")
      expect(response.body).to include("3 authors, 1 reviewers, 4 people in all")
      names = doc.css("tbody tr td.person").map { |td| td.text.strip.split.first }
      expect(names).to eq(%w[Dave Alice Bob Carol])
      expect(doc.css("tbody tr[data-list-filter-target='item']").map { |tr| tr["data-name"] }).to all(match(/\A[a-z]/))
      expect(doc.at_css("[data-controller='list-filter'] input[type='search'][data-action='input->list-filter#filter']")).to be_present
      expect(doc.css("tbody tr").first.at_css(".badge").text).to eq("committer since Feb 2026")
      expect(doc.css("th.sortable").size).to eq(6)
      expect(doc.at_css("th.sortable.is-active a")["href"]).to include("sort=credits").and include("dir=asc")
      scatter = JSON.parse(doc.at_css("[data-release-chart-kind-value='scatter']")["data-release-chart-data-value"])
      expect(scatter["points"].map { |pt| [ pt["name"].split.first, pt["group"] ] }).to contain_exactly(
        [ "Dave", "committers" ], [ "Alice", "committers" ], [ "Bob", "others" ], [ "Carol", "others" ])
      expect(scatter["label_min"]).to eq(0)
      ranked = JSON.parse(doc.at_css("[data-release-chart-kind-value='ranked']")["data-release-chart-data-value"])
      expect(ranked["series"].map { |s| s["label"] }).to eq(%w[authored reviewed])
      expect(ranked["series"].map { |s| s["values"] }).to eq([ [ 2, 1, 1, 0 ], [ 0, 0, 0, 1 ] ])
      expect(response.body).to include(person_path("bob@example.com"))
      expect(doc.at_css("tbody tr td.person a")["href"]).to start_with("/stats/releases/19/person/")
      expect(doc.css("thead th").size).to eq(9)
      expect(doc.at_css(".stats-foot").text).to include("Showing 4 of 4")
      expect(response.body).not_to include("not linked to a person")

      get "/stats/releases/19/people", params: { committers: "excluded", sort: "messages", dir: "desc" }
      names = Nokogiri::HTML(response.body).css("tbody tr td.person").map { |td| td.text.strip.split.first }
      expect(names).to eq(%w[Bob Carol])

      get "/stats/releases/19/people.csv"
      expect(response.media_type).to eq("text/csv")
      expect(response.body.lines.first).to start_with("rank,name,company,credits")
      expect(response.body.lines.size).to eq(5)
      expect(response.body.lines[1]).to start_with("1,Dave")

      get "/stats/releases/19/people.csv", params: { committers: "excluded" }
      expect(response.body.lines.size).to eq(3)
    end

    it "neutralizes formula cells in the CSV" do
      evil = create(:alias, name: "=cmd", email: "evil@example.com")
      CommitPerson.create!(commit: fx.commits[:c1], person: evil.person, role: "reviewer", source: "parsed", raw_name: "=cmd", raw_email: "evil@example.com")
      Rails.cache.clear
      get "/stats/releases/19/people.csv"
      expect(response.body).to include("'=cmd")
      expect(response.body).not_to match(/^\d+,=cmd/)
    end

    it "ranks the share charts by their own measure and caps the people list" do
      extra = (1..42).map { |i| create(:alias, name: "Extra #{i.to_s.rjust(2, '0')}", email: "extra#{i}@example.com").person }
      scope = fx.commits.values_at(:c1, :c2, :c3, :c4b)
      extra.each_with_index do |person, i|
        PersonAffiliation.create!(person: person, company: "Zeta", source: "manual")
        CommitPerson.create!(commit: scope[i % 4], person: person, role: "reviewer", source: "parsed", raw_name: person.display_name)
      end
      Rails.cache.clear
      get "/stats/releases/19/companies"
      doc = Nokogiri::HTML(response.body)
      shares = doc.css("[data-release-chart-kind-value='ranked']").map { |c| JSON.parse(c["data-release-chart-data-value"]) }
      expect(shares[1]["categories"].first(3)).to eq([ "Acme", "Beta Corp", "Zeta" ])
      expect(shares[2]["categories"].first).to eq("Zeta")
      expect(shares[2]["series"].first["values"].first).to eq(4)
      zeta = doc.css("tbody tr").find { |tr| tr.at_css("td.txt").text == "Zeta" }
      expect(zeta.at_css(".info")["title"]).to end_with("Extra 40\nand 2 more")
    end

    it "links back to the top list when showing all" do
      get "/stats/releases/19/people", params: { all: "1" }
      link = Nokogiri::HTML(response.body).css(".stats-foot a").find { |a| a.text == "top 20" }
      expect(link["href"]).not_to include("all=")
    end

    it "notes credits not linked to a person" do
      CommitPerson.create!(commit: fx.commits[:c1], role: "reviewer", source: "parsed", raw_name: "Nobody Known")
      get "/stats/releases/19/people"
      expect(Nokogiri::HTML(response.body).at_css(".stats-foot").text).to include("1 credits not linked to a person are not listed")
    end

    it "renders the companies tab with tiles, charts, table and disclaimer" do
      get "/stats/releases/19/companies"
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css(".stats-tab.is-active").text).to eq("Companies")
      expect(doc.css(".stats-tile").size).to eq(4)
      expect(doc.css(".stats-tile .v").map(&:text)).to eq(%w[2 60% 50% 1])
      expect(doc.css("[data-release-chart-kind-value='ranked']").size).to eq(3)
      expect(doc.css("[data-release-chart-kind-value='rows']").size).to eq(2)
      share = JSON.parse(doc.css("[data-release-chart-kind-value='ranked']")[1]["data-release-chart-data-value"])
      expect(share["categories"]).to eq([ "Acme", "Beta Corp", "other companies", Stats::Affiliations::UNKNOWN ])
      expect(share["series"].first["values"]).to eq([ 1, 1, 0, 2 ])
      expect(share).to include("percent_of" => 4, "gray_tail" => 2, "total_labels" => true)
      expect(doc.css("tbody tr td.txt").map(&:text)).to eq([ "Acme", "Beta Corp", Stats::Affiliations::UNKNOWN ])
      expect(doc.css("tbody tr").map { |tr| tr.at_css("td").text }).to eq(%w[1 2 -])
      expect(doc.at_css("tbody tr .info")["title"]).to eq("2 people, 1 committer\nAlice (committer)\nCarol")
      expect(response.body).to include("privacy policy")
      expect(doc.at_css(".stats-disclaimer a")["href"]).to eq(help_path("privacy"))
      get "/stats/releases/19/companies.csv"
      expect(response.media_type).to eq("text/csv")
      expect(response.body.lines.first).to start_with("rank,company,people,credits")
      expect(response.body.lines.size).to eq(4)
    end

    it "renders the committers tab" do
      get "/stats/releases/19/committers"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("one scale; shaded months are outside the main phase")
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css(".stats-tab.is-active").text).to eq("Committers")
      expect(doc.css(".stats-chips a.stats-chip[href*='/person/']")).to be_empty
      expect(doc.css("[data-release-chart-kind-value='scatter']").size).to eq(1)
      expect(doc.css("[data-release-chart-kind-value='ranked']").size).to eq(3)
      expect(doc.css("[data-release-chart-kind-value='rows']").size).to eq(4)
      expect(doc.css("thead abbr[title]").size).to eq(8)
      expect(doc.css("tbody tr td.txt").map { |td| td.text.strip }).to eq([ "Alice", "Dave since Feb 2026" ])
      expect(doc.at_css("tbody tr td.txt a")["href"]).to eq("/stats/releases/19/person/alice@example.com")
      expect(doc.css("tbody tr:first-child td").drop(1).map { |td| td.text.strip }).to eq(%w[3 1 2 2 1 130 - 100% 50% 1 1 1 33%])
      expect(doc.at_css(".stats-foot a")["href"]).to eq("/stats/releases/19/committers.csv")
      get "/stats/releases/19/committers.csv"
      expect(response.media_type).to eq("text/csv")
      expect(response.body.lines.first.chomp).to eq("committer,commits,own,for_others,authors,reverts,lines,reviewed_for_others,judged,as_posted,alone,messages,threads,people,backported")
      expect(response.body.lines.size).to eq(3)
      get "/stats/releases/19"
      expect(response.body).to include("All committers")
      expect(response.body).to include("/stats/releases/19/committers")
    end

    it "renders a committer's person view" do
      get "/stats/releases/19/person/alice@example.com"
      expect(response).to have_http_status(:ok)
      body = response.body
      doc = Nokogiri::HTML(body)
      expect(body).to include("Alice in PG19")
      expect(doc.at_css(".stats-head .s").text).to start_with("committer, Acme (privacy policy)")
      expect(doc.at_css(".stats-head abbr")["title"]).to start_with("Affiliation from public sources")
      expect(body).to include(help_path("privacy"))
      expect(body).to include("#1 of 2 committers")
      expect(body).to include("release 50%")
      expect(body).to include("Sole reviewer")
      expect(body).to include("Committed for")
      expect(doc.at_css(".stats-tab.is-active").text).to eq("Alice")
      expect(doc.at_css(".stats-head a[href='/person/alice@example.com']")).to be_present
      pill = ->(key) { doc.css(".stats-tile").find { |t| t.at_css(".k")&.text&.start_with?(key) }&.at_css(".stats-pill") }
      expect(pill.call("Reverts")["class"].split).to include("is-bad")
      expect(pill.call("Sole reviewer").text.strip).to eq("= release 50%")
      expect(pill.call("Sole reviewer")["class"].split).to eq(%w[stats-pill])
      lines = doc.css(".stats-tile").find { |t| t.at_css(".k")&.text == "Lines" }
      expect(lines.at_css(".v").text).to eq("130")
      expect(doc.css(".stats-head a").map { |a| a["href"] }).to include("/stats/releases/20/person/alice@example.com")
      expect(doc.css(".stats-list a").map { |a| a["href"] }).to include("/stats/releases/19/person/bob@example.com")
      expect(doc.css("[data-release-chart-kind-value='strips']").size).to eq(1)
    end

    it "renders a contributor's person view and 404s for strangers" do
      get "/stats/releases/19/person/bob@example.com"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("#3 of 3 authors")
      expect(response.body).to include("Committed by")
      expect(response.body).not_to include("Sole reviewer")
      doc = Nokogiri::HTML(response.body)
      crediting = doc.css(".stats-tile").find { |t| t.at_css(".k")&.text == "Crediting a reviewer" }
      expect(crediting.at_css(".stats-pill")["class"].split).to include("is-good")
      expect(doc.css(".stats-pill.is-good").size).to eq(1)
      expect(doc.css(".stats-card").find { |c| c.at_css(".t")&.text == "Reviewed" }.at_css(".s").text).to eq("credits on committers' commits")
      get "/stats/releases/19/person/nobody@example.com"
      expect(response).to have_http_status(:not_found)
      get "/stats/releases/19/people"
      expect(response.body).to include("/stats/releases/19/person/bob@example.com")
      get "/stats/releases/19"
      expect(Nokogiri::HTML(response.body).css(".stats-podium a").map { |a| a["href"] }).to include("/stats/releases/19/person/alice@example.com")
    end

    it "links the people tab from the overview podium" do
      get "/stats/releases/19"
      expect(response.body).to include("All people")
      expect(response.body).to include("/stats/releases/19/people")
    end

    it "404s for unknown majors" do
      get "/stats/releases/7"
      expect(response).to have_http_status(:not_found)
      get "/stats/releases/abc"
      expect(response).to have_http_status(:not_found)
      get "/stats/releases/7/pulse"
      expect(response).to have_http_status(:not_found)
      get "/stats/releases/7/people"
      expect(response).to have_http_status(:not_found)
      get "/stats/releases/7/companies"
      expect(response).to have_http_status(:not_found)
      get "/stats/releases/7/committers"
      expect(response).to have_http_status(:not_found)
      get "/stats/releases/7/person/alice@example.com"
      expect(response).to have_http_status(:not_found)
    end

    it "keeps the release-only tiles and legend" do
      get "/stats/releases/19/pulse"
      expect(response.body).to include("early / stabilization: only threads that landed in PG19")
      get "/stats/releases/19/person/alice@example.com"
      expect(response.body).to include("Started after the 19 branch point")
      get "/stats/releases/19"
      expect(response.body).to include("commits in the 19 branch that are not in 18")
      expect(response.body).to include("to an earlier branch too")
    end

    it "renders a year on every tab" do
      get "/stats/years/2026"
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("h1").text).to eq("2026 statistics")
      expect(doc.css(".stats-chip").map(&:text).map(&:squish)).to eq([ "2026 (in progress)", "2025", "2024", "2023", "2022", "2021", "2020", "2019", "2018", "2017" ])
      expect(doc.at_css(".stats-chip.is-active.is-dim").text).to include("2026")
      expect(doc.at_css(".stats-range").text).to eq("Year: 2026-01-01 to today")
      expect(response.body).to include("committed between 2026-01-01 and today, one per change, backports collapsed")
      expect(response.body).to include("cherry-picked to another branch too")
      expect(response.body).to include("Who shaped 2026")
      expect(doc.css(".stats-tab").map(&:text)).to eq([ "Overview", "Pulse", "Companies", "People", "Committers" ])
      expect(doc.css(".stats-chip").map { |a| a["href"] }).to include("/stats/years/2025")

      get "/stats/years/2026/pulse"
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("early / stabilization")
      data = JSON.parse(Nokogiri::HTML(response.body).at_css("[data-release-chart-kind-value='strips']")["data-release-chart-data-value"])
      expect(data["windows"].map { |w| w["phase"] }).to eq([ "middle" ])
      expect(data["events"].map { |e| e["label"] }).to eq([ "19 branched (beta1)" ])

      get "/stats/years/2026/people"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("/stats/years/2026/person/alice@example.com")
      expect(response.body).to include("/stats/years/2026/people?")
      get "/stats/years/2026/people.csv"
      expect(response.headers["Content-Disposition"]).to include("2026-people.csv")

      get "/stats/years/2026/companies"
      expect(response).to have_http_status(:ok)
      get "/stats/years/2026/companies.csv"
      expect(response.headers["Content-Disposition"]).to include("2026-companies.csv")

      get "/stats/years/2026/committers"
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("shaded months")
      get "/stats/years/2026/committers.csv"
      expect(response.headers["Content-Disposition"]).to include("2026-committers.csv")

      get "/stats/years/2026/person/alice@example.com"
      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("Alice in 2026")
      expect(body).not_to include("branch point")
      expect(body).to include("in the year")
      expect(body).to include("year 75%")
      expect(body).to include("year 25%")
      expect(body).not_to include("release 75%")
      expect(Nokogiri::HTML(body).css(".stats-head a").map { |a| a["href"] }).to include("/stats/years/2025/person/alice@example.com")
    end

    it "keeps companies out of years before the curated data" do
      get "/stats/years/2025"
      expect(Nokogiri::HTML(response.body).css(".stats-tab").map(&:text)).not_to include("Companies")
      get "/stats/years/2025/companies"
      expect(response).to have_http_status(:not_found)
      get "/stats/years/2026/companies"
      expect(Nokogiri::HTML(response.body).css(".stats-chip").find { |a| a.text.include?("2025") }["href"]).to eq("/stats/years/2025")
    end

    it "renders a development cycle" do
      get "/stats/cycles/2025"
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("h1").text).to eq("2025/26 cycle statistics")
      expect(doc.css(".stats-chip").map(&:text).map(&:squish)).to eq([ "2026/27 (in progress)", "2025/26" ])
      expect(doc.at_css(".stats-range").text).to eq("Master: 2025-05-05 (18 branched) to 2026-06-01 (19 branched)")
      expect(response.body).to include("Who shaped the 2025/26 cycle")
      expect(doc.css(".stats-tab").map(&:text)).to include("Companies")
      get "/stats/cycles/2025/pulse"
      expect(response).to have_http_status(:ok)
      get "/stats/cycles/2025/people.csv"
      expect(response.headers["Content-Disposition"]).to include("2025-26-people.csv")
      get "/stats/cycles/2026/person/alice@example.com"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Alice in the 2026/27 cycle")
    end

    it "renders the three trend pages" do
      { "releases" => "Release over release", "years" => "Year over year", "cycles" => "Cycle over cycle" }.each do |segment, title|
        get "/stats/trends/#{segment}"
        expect(response).to have_http_status(:ok)
        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css("h1").text).to eq(title)
        expect(doc.at_css(".stats-chip.is-active").text).to eq(title)
        expect(doc.css(".stats-band").map(&:text).join).to include("Headline shifts", "Volume", "From the LLM")
        charts = doc.css("[data-release-chart-kind-value='trend']")
        expect(charts.size).to eq(22)
        charts.each do |chart|
          data = JSON.parse(chart["data-release-chart-data-value"])
          expect(data.keys).to include("categories", "lines", "unit", "paths")
          expect(data["paths"].size).to eq(data["categories"].size)
        end
      end
    end

    it "shows the year trend with headline and period links" do
      get "/stats/trends/years"
      doc = Nokogiri::HTML(response.body)
      commits = doc.css(".stats-trend").find { |c| c.at_css(".t").text == "Commits" }
      data = JSON.parse(commits.at_css("[data-release-chart-data-value]")["data-release-chart-data-value"])
      expect(data["categories"].first).to eq("2017")
      expect(data["categories"].last).to eq("2026")
      expect(data["open"].last).to be(true)
      expect(data["paths"].last).to eq("/stats/years/2026")
      expect(commits.at_css(".stats-trend-head").text).to include("2017", "2025")
    end

    it "404s on an unknown trend" do
      get "/stats/trends/weeks"
      expect(response).to have_http_status(:not_found)
    end

    it "404s for unknown years and cycles" do
      get "/stats/years/1990"
      expect(response).to have_http_status(:not_found)
      get "/stats/years/abc"
      expect(response).to have_http_status(:not_found)
      get "/stats/years/2016/pulse"
      expect(response).to have_http_status(:not_found)
      get "/stats/cycles/2024" # no 17 beta1 in the fixture
      expect(response).to have_http_status(:not_found)
      get "/stats/cycles/2025/person/nobody@example.com"
      expect(response).to have_http_status(:not_found)
    end
  end
end
