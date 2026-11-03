require "rails_helper"

RSpec.describe CommitImport::PersonOverrides do
  describe ".email_for" do
    it "corrects a known-bad email" do
      key, value = described_class::EMAILS.first
      expect(described_class.email_for(key.upcase, nil)).to eq(value)
    end

    it "passes an unknown email through lowercased" do
      expect(described_class.email_for("A@X", "Justin Prysby")).to eq("a@x")
    end

    it "maps a misspelled name when there is no email" do
      key, value = described_class::NAMES.first
      expect(described_class.email_for(nil, "  #{key.upcase} ")).to eq(value)
    end

    it "returns nil for an unknown name" do
      expect(described_class.email_for(nil, "Nobody Known")).to be_nil
    end
  end

  it "stores lowercased keys and email values" do
    maps = described_class::EMAILS.merge(described_class::NAMES)
    expect(maps.keys.reject { |k| k == k.downcase.squeeze(" ").strip }).to be_empty
    expect(maps.values.reject { |v| v.match?(/\A[^@\s]+@[^@\s]+\z/) }).to be_empty
    expect(described_class::EMAILS.select { |k, v| k == v }).to be_empty
  end
end
