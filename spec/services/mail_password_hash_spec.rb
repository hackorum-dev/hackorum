require "rails_helper"

RSpec.describe MailPasswordHash do
  it "creates a salted SHA512-CRYPT hash that verifies" do
    hash = described_class.create("correct horse battery")
    expect(hash).to match(%r{\A\{SHA512-CRYPT\}\$6\$[./A-Za-z0-9]{16}\$[./A-Za-z0-9]{86}\z})
    expect(described_class.matches?(hash, "correct horse battery")).to be(true)
    expect(described_class.matches?(hash, "wrong")).to be(false)
    expect(described_class.create("correct horse battery")).not_to eq(hash)
  end
end
