require "rails_helper"

RSpec.describe Feature do
  describe ".valid?" do
    it "returns true for known feature names (symbol or string)" do
      expect(Feature.valid?(:email_sending)).to be true
      expect(Feature.valid?("email_sending")).to be true
    end

    it "knows the patchset_lineage feature" do
      expect(Feature.valid?("patchset_lineage")).to be true
    end

    it "returns false for unknown names" do
      expect(Feature.valid?(:bogus)).to be false
    end
  end

  describe ".label" do
    it "returns the display label" do
      expect(Feature.label(:email_sending)).to eq("Email sending")
    end
  end
end
