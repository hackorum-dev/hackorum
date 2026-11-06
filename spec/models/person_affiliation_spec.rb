require "rails_helper"

RSpec.describe PersonAffiliation do
  let(:person) { create(:person) }

  it "needs a company and a known source" do
    expect(described_class.new(person: person, company: "", source: "manual")).not_to be_valid
    expect(described_class.new(person: person, company: "Acme", source: "guess")).not_to be_valid
    expect(described_class.new(person: person, company: "Acme", source: "manual")).to be_valid
  end

  it "rejects a range that ends before it starts" do
    row = described_class.new(person: person, company: "Acme", source: "manual", since: Date.new(2025, 2, 1), until: Date.new(2025, 1, 1))
    expect(row).not_to be_valid
  end

  it "is unique per person, company and since, nulls included" do
    described_class.create!(person: person, company: "Acme", source: "manual")
    expect { described_class.create!(person: person, company: "Acme", source: "domain") }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
