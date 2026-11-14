require "rails_helper"

RSpec.describe MailingList, "stats_bit" do
  it "assigns the lowest free bit" do
    a = create(:mailing_list)
    b = create(:mailing_list)
    expect([ a.stats_bit, b.stats_bit ]).to eq([ 0, 1 ])
    a.destroy
    expect(create(:mailing_list).stats_bit).to eq(0)
  end

  it "keeps an explicit bit" do
    expect(create(:mailing_list, stats_bit: 5).stats_bit).to eq(5)
  end

  it "rejects a duplicate bit" do
    create(:mailing_list, stats_bit: 2)
    expect { create(:mailing_list, stats_bit: 2) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "knows its stats default" do
    expect(build(:mailing_list).stats_default?).to be(true)
    expect(build(:mailing_list, archived: true).stats_default?).to be(false)
    expect(build(:mailing_list, hidden_by_default: true).stats_default?).to be(false)
  end
end
