require "rails_helper"

RSpec.describe Stats::Affiliations do
  let!(:fx) { build_stats_release_fixture }
  let(:lookup) { described_class.new(fx.people.values.map(&:id)) }

  it "picks the row covering the date, newest since first" do
    bob = fx.people["bob"].id
    expect(lookup.company_for(bob, Time.zone.parse("2025-10-10"))).to eq("Beta Corp")
    expect(lookup.company_for(bob, Time.zone.parse("2025-12-05"))).to eq("Gamma")
    expect(lookup.company_for(fx.people["alice"].id, Time.zone.parse("2024-06-01"))).to be_nil
    expect(lookup.company_for(fx.people["alice"].id, Time.zone.parse("2026-01-15"))).to eq("Acme")
    expect(lookup.company_for(fx.people["dave"].id, Time.zone.parse("2026-02-01"))).to be_nil
    expect(lookup.company_for(nil, Time.zone.parse("2026-02-01"))).to be_nil
  end

  it "breaks ties between undated rows by source" do
    dave = fx.people["dave"]
    PersonAffiliation.create!(person: dave, company: "Old Co", source: "domain")
    PersonAffiliation.create!(person: dave, company: "New Co", source: "contributors_page")
    expect(described_class.new([ dave.id ]).company_for(dave.id, Time.zone.parse("2026-02-01"))).to eq("New Co")
  end

  it "labels the unknown bucket" do
    expect(described_class.label(nil)).to eq(described_class::UNKNOWN)
    expect(described_class.label("Acme")).to eq("Acme")
  end
end
