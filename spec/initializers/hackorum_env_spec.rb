require "rails_helper"

RSpec.describe Hackorum, ".env" do
  around do |example|
    old = ENV["HACKORUM_ENV"]
    example.run
  ensure
    ENV["HACKORUM_ENV"] = old
  end

  it "defaults to production when unset" do
    ENV.delete("HACKORUM_ENV")
    expect(Hackorum.env).to eq("production")
    expect(Hackorum.staging?).to be(false)
  end

  it "treats empty as unset" do
    ENV["HACKORUM_ENV"] = ""
    expect(Hackorum.env).to eq("production")
  end

  it "recognizes staging" do
    ENV["HACKORUM_ENV"] = "staging"
    expect(Hackorum.env).to eq("staging")
    expect(Hackorum.staging?).to be(true)
  end

  it "rejects unknown values" do
    ENV["HACKORUM_ENV"] = "beta"
    expect { Hackorum.env }.to raise_error(ArgumentError, /HACKORUM_ENV/)
  end
end
