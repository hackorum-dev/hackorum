require "rails_helper"

RSpec.describe Stats::Lists::Builder do
  let!(:fx) { build_stats_lists_fixture }
  let(:cols) { %w[messages messages_committer messages_contributor people people_committer people_contributor threads_active threads_new newcomers_community newcomers_selection] }

  before { described_class.new.run! }

  def vol(gran, mask, start)
    StatsListVolume.find_by!(gran: gran, list_mask: mask, period_start: Date.parse(start))
  end

  def row(gran, mask, start) = vol(gran, mask, start).attributes.slice(*cols).values

  it "counts the default selection per month" do
    expect(row("month", 3, "2024-01-01")).to eq([ 4, 0, 1, 4, 0, 1, 2, 2, 3, 4 ])
    expect(row("month", 3, "2024-02-01")).to eq([ 2, 1, 0, 2, 1, 0, 2, 1, 0, 0 ])
    expect(row("month", 3, "2024-03-01")).to eq([ 1, 0, 0, 1, 0, 0, 1, 0, 0, 0 ])
  end

  it "separates community and selection newcomers" do
    expect(vol("month", 1, "2024-01-01").slice(:newcomers_community, :newcomers_selection).values).to eq([ 2, 3 ])
    expect(vol("month", 1, "2024-02-01").newcomers_selection).to eq(1)
  end

  it "counts a cross-post once" do
    expect(vol("month", 7, "2024-01-01").messages).to eq(5)
    expect(vol("month", 2, "2024-01-01").messages).to eq(2)
  end

  it "builds every granularity and mask" do
    expect(vol("week", 3, "2024-01-01").messages).to eq(4)
    expect(vol("quarter", 3, "2024-01-01").slice(:messages, :people).values).to eq([ 7, 4 ])
    expect(vol("year", 3, "2024-01-01").people).to eq(4)
    expect(StatsListVolume.where(gran: "month", period_start: Date.new(2024, 1, 1)).pluck(:list_mask).sort).to eq((1..7).to_a)
  end

  it "stores person weeks, firsts and messages per list" do
    expect(StatsPersonWeek.count).to eq(10)
    ann = StatsPersonWeek.find_by!(person_id: fx[:people][:ann].id, week: Date.new(2024, 1, 1), list_bit: 0)
    expect(ann.slice(:messages, :threads, :active_days, :patch_mails, :threads_started).values).to eq([ 1, 1, 1, 1, 1 ])
    expect(StatsPersonFirst.count).to eq(8)
    expect(StatsPersonFirst.find_by!(person_id: fx[:people][:cora].id, list_bit: 0).first_message_id).to eq(fx[:messages][:m4].id)
    by_list = StatsListMessagesByList.where(gran: "month", period_start: Date.new(2024, 1, 1)).pluck(:list_bit, :messages).to_h
    expect(by_list).to eq(0 => 3, 1 => 2, 2 => 1)
  end

  it "classifies newcomers" do
    got = StatsNewcomer.all.index_by(&:person_id)
    expect(got.size).to eq(5)
    check = lambda do |who, mask, path, back, offsets, months, contributor|
      n = got.fetch(fx[:people][who].id)
      expect([ n.first_list_mask, n.path, n.came_back, n.active_month_offsets, n.active_months_2y, n.contributor ])
        .to eq([ mask, path, back, offsets, months, contributor ])
    end
    check.(:ann, 1, "patch", true, [ 0, 2 ], 2, false)
    check.(:bob, 2, "report", true, [ 0, 1 ], 2, false)
    check.(:carl, 1, "discussion", true, [ 0, 1 ], 2, false)
    check.(:cora, 4, "report", false, [ 0 ], 1, true)
    check.(:dan, 1, "report", false, [ 0 ], 1, false)
    expect(got[fx[:people][:dan].id].committer_at).to eq(Time.utc(2023, 6, 1, 12))
    expect(got[fx[:people][:carl].id].committer_at).to eq(Time.utc(2024, 2, 1, 12))
  end

  it "counts a committer who is also a contributor as committer" do
    expect(row("year", 1, "2023-01-01")).to eq([ 1, 1, 0, 1, 1, 0, 1, 1, 1, 1 ])
  end

  it "ignores pending and unlisted messages" do
    ann = StatsPersonWeek.find_by!(person_id: fx[:people][:ann].id, week: Date.new(2024, 1, 1), list_bit: 0)
    expect(ann.messages).to eq(1)
    expect(StatsPersonWeek.where(person_id: fx[:people][:bob].id, week: Date.new(2024, 1, 1)).sum(:messages)).to eq(1)
    expect(vol("week", 7, "2024-01-01").messages).to eq(5)
  end

  it "is idempotent" do
    described_class.new.run!
    expect(StatsPersonWeek.count).to eq(10)
    expect(row("month", 3, "2024-01-01")).to eq([ 4, 0, 1, 4, 0, 1, 2, 2, 3, 4 ])
  end

  it "refuses more than 10 lists" do
    (MailingList.where.not(stats_bit: nil).count...11).each { |i| create(:mailing_list, identifier: "extra-#{i}", display_name: "Extra #{i}") }
    expect { described_class.new.run! }.to raise_error(ArgumentError, /too many lists.*11/)
  end

  it "precomputes regulars for default, single and all masks" do
    expect(StatsRegularsMonthly.distinct.pluck(:list_mask).sort).to eq([ 1, 2, 3, 4, 7 ])
    expect(StatsRegularsTotal.distinct.pluck(:list_mask).sort).to eq([ 1, 2, 3, 4, 7 ])
    jan = StatsRegularsMonthly.where(list_mask: 3, month: Date.new(2024, 1, 1)).index_by(&:person_id)
    expect(jan.keys).to contain_exactly(*fx[:people].values_at(:ann, :bob, :carl, :cora).map(&:id))
    expect(jan.values.map(&:rank_messages).sort).to eq([ 1, 2, 3, 4 ])
    expect(jan[fx[:people][:cora].id].score_messages).to eq(1)
  end

  it "counts a cross-post once in regulars" do
    cora = fx[:people][:cora].id
    jan3 = StatsRegularsMonthly.find_by!(list_mask: 3, month: Date.new(2024, 1, 1), person_id: cora)
    jan1 = StatsRegularsMonthly.find_by!(list_mask: 1, month: Date.new(2024, 1, 1), person_id: cora)
    expect(jan3.score_messages).to eq(jan1.score_messages)
  end

  it "stores second message and top 50" do
    got = StatsNewcomer.all.index_by(&:person_id)
    ann = got[fx[:people][:ann].id]
    expect(ann.second_at).to eq(fx[:messages][:m7].created_at)
    expect(ann.reached_top50_at.to_date).to eq(Date.new(2024, 1, 31))
    expect(got[fx[:people][:cora].id].second_at).to eq(fx[:messages][:m4].created_at)
    expect(got[fx[:people][:dan].id].second_at).to be_nil
    expect(got[fx[:people][:dan].id].reached_top50_at.to_date).to eq(Date.new(2023, 12, 31))
  end
end
