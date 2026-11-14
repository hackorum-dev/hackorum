require "rails_helper"

RSpec.describe Stats::Lists::Regulars do
  let!(:fx) { build_stats_lists_fixture }
  let(:today) { Date.new(2024, 4, 10) }

  before { Stats::Lists::Builder.new.run! }

  def build(q = {}, **opts)
    params = Stats::ListsParams.new(params: { from: "2024-01", to: "2024-03" }.merge(q), today: today)
    described_class.new(params, today: today, **opts).to_h
  end

  it "builds the heatmap and table from the precomputed mask" do
    d = build(score: "messages")
    expect(d[:approximate]).to be(false)
    expect(d[:months]).to eq(%w[2024-01 2024-02 2024-03])
    expect(d[:at]).to eq("2024-03")
    expect(d[:heatmap][:y]).to include("Ann", "Carl")
    expect(d[:heatmap][:cells]).to all(satisfy { |c| c.size == 5 && (1..4).cover?(c[2]) })
    expect(d[:table].first.keys).to include(:rank, :name, :email, :tag, :score, :spark, :year_ago)
    expect(d[:table].map { |r| r[:rank] }).to eq((1..d[:table].size).to_a)
    expect(d[:table].first[:spark].size).to eq(24)
  end

  it "opens on the last full month" do
    m = create(:message, sender: Alias.find_by!(name: "Bob"), topic: create(:topic),
                         created_at: Time.utc(2024, 4, 2, 10), updated_at: Time.utc(2024, 4, 2, 10))
    create(:message_mailing_list, message: m, mailing_list: fx[:lists][:hackers])
    Stats::Lists::Builder.new.run!
    d = build({ to: "2024-04" })
    expect(d[:months].last).to eq("2024-04")
    expect(d[:at]).to eq("2024-03")
  end

  it "tags committers by date" do
    jan = build(score: "messages", at: "2024-01")[:table].index_by { |r| r[:name] }
    feb = build(score: "messages", at: "2024-02")[:table].index_by { |r| r[:name] }
    expect(jan["Carl"][:tag]).to be_nil
    expect(feb["Carl"][:tag]).to eq("committer")
    expect(jan["Cora"][:tag]).to eq("contributor")
    dec = build({ from: "2023-12" }, score: "messages", at: "2023-12")[:table].index_by { |r| r[:name] }
    expect(dec["Dan"][:tag]).to eq("committer")
  end

  it "fills the spark further back than the year-ago month" do
    m = create(:message, sender: Alias.find_by!(name: "Ann"), topic: create(:topic),
                         created_at: Time.utc(2025, 2, 5, 10), updated_at: Time.utc(2025, 2, 5, 10))
    create(:message_mailing_list, message: m, mailing_list: fx[:lists][:hackers])
    Stats::Lists::Builder.new.run!
    later = Date.new(2025, 3, 10)
    params = Stats::ListsParams.new(params: { from: "2025-02", to: "2025-02" }, today: later)
    ann = described_class.new(params, score: "messages", today: later).to_h[:table].find { |r| r[:name] == "Ann" }
    expect(ann[:spark][10]).to be > 0 # 2024-01
  end

  it "falls back to an on-the-fly computation" do
    d = build({ lists: "pgsql-hackers,pgsql-committers" })
    expect(d[:approximate]).to be(true)
    expect(d[:table]).not_to be_empty
  end

  it "draws everyone who was in the rolling top 10 and pins the end month's leaders" do
    stub_const("#{described_class}::BUMP_TOP", 1)
    stub_const("#{described_class}::BUMP_PINNED", 1)
    bump = build(score: "messages", at: "2024-03")[:bump]
    by_label = bump[:lines].index_by { |l| l[:label] }
    # Bob leads only Dec-Feb (ties go to the lower id); Ann leads at the end
    expect(by_label.keys).to include("Ann", "Bob")
    ends = bump[:lines].filter_map { |l| l[:values].last }
    expect(ends.sort).to eq([ 1, 2, 3, 4 ]) # Ann, Bob, Carl, Cora over Jan-Mar
    stub_const("#{described_class}::HEAT_TOP", 1)
    expect(build(score: "messages", at: "2024-03")[:bump][:lines].map { |l| l[:label] }).to contain_exactly("Ann", "Bob")
    expect(by_label.values.map { |l| l[:id] }).to all(be_a(Integer))
    ends = bump[:lines].select { |l| l[:values].last }.sort_by { |l| l[:values].last }.first(1).map { |l| l[:id] }
    expect(bump[:pinned]).to eq(ends)
    expect(bump[:pinned]).to eq([ fx[:people][:ann].id ])
  end

  it "ends the bump chart at the last full month" do
    m = create(:message, sender: Alias.find_by!(name: "Bob"), topic: create(:topic),
                         created_at: Time.utc(2024, 4, 2, 10), updated_at: Time.utc(2024, 4, 2, 10))
    create(:message_mailing_list, message: m, mailing_list: fx[:lists][:hackers])
    Stats::Lists::Builder.new.run!
    expect(build({ to: "2024-04" })[:bump][:categories].last).to eq("2024-03")
  end

  it "ranks bump lines by the last three months combined" do
    lines = build({ from: "2024-02", to: "2024-03" }, score: "messages")[:bump][:lines].index_by { |l| l[:label] }
    # Mar alone is only Ann; Jan-Mar adds Carl (2), Cora (2) and Bob (2)
    expect(lines.keys).to include("Ann", "Carl", "Cora", "Bob")
    expect(lines["Ann"][:values].last).to eq(1)
  end

  it "adds bump and concentration" do
    d = build
    expect(d[:bump][:lines]).not_to be_empty
    shares = d[:concentration][:series]
    expect(shares.map { |s| s[:label] }).to eq([ "top 10", "11-50", "everyone else" ])
    d[:concentration][:categories].each_index do |i|
      total = shares.sum { |s| s[:values][i] }
      expect(total).to be_within(0.5).of(100).or eq(0)
    end
  end

  it "stops at the last built month" do
    StatsRegularsMonthly.where("month > ?", "2024-03-01").delete_all
    d = described_class.new(Stats::ListsParams.new(params: { from: "2024-01", to: "2024-06" }, today: Date.new(2024, 6, 10)), today: Date.new(2024, 6, 10)).to_h
    expect(d[:months].last).to eq("2024-03")
    expect(d[:at]).to eq("2024-03")
    expect(d[:table]).not_to be_empty
  end

  it "keeps the last built month when the range is entirely after it" do
    StatsRegularsMonthly.where("month > ?", "2024-03-01").delete_all
    t = Date.new(2024, 6, 10)
    d = described_class.new(Stats::ListsParams.new(params: { from: "2024-06", to: "2024-06" }, today: t), today: t).to_h
    expect(d[:months]).to eq([ "2024-03" ])
    expect(d[:at]).to eq("2024-03")
    expect(d[:table]).not_to be_empty
  end

  it "adds the score to heatmap cells and caps the rows" do
    expect(build(score: "messages")[:heatmap][:cells]).to all(satisfy { |c| c.size == 5 && c[4].is_a?(Integer) })
    stub_const("#{described_class}::HEAT_ROWS", 2)
    heat = build(score: "messages")[:heatmap]
    expect(heat[:capped]).to be(true)
    expect(heat[:y].size).to eq(2)
    expect(heat[:cells].map { |c| c[1] }.uniq.sort).to eq([ 0, 1 ])
  end

  it "survives an empty database" do
    StatsRegularsMonthly.delete_all
    StatsRegularsTotal.delete_all
    StatsPersonWeek.delete_all
    expect { build }.not_to raise_error
  end
end
