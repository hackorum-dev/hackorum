require "rails_helper"

RSpec.describe MessageBodyText do
  def strip(body)
    described_class.strip_quotes(body)
  end

  it "drops quoted lines and one-line attributions" do
    expect(strip("On Mon, X wrote:\n> first idea.\nHere is v1.\n")).to eq("Here is v1.\n")
    expect(strip("Hi\n>> deep\n>shallow\n > indented stays\nBye\n")).to eq("Hi\n > indented stays\nBye\n")
  end

  it "drops an attribution wrapped over two lines" do
    body = "Reply.\nOn Tue, Jan 1, 2025 at 10:00 AM Some Body <s@example.com>\nwrote:\n> q\nKeep.\n"

    expect(strip(body)).to eq("Reply.\nKeep.\n")
  end

  it "keeps a line that only looks like half an attribution" do
    expect(strip("On the other hand\nthis is fine.\n")).to eq("On the other hand\nthis is fine.\n")
    expect(strip("As he wrote:\nnothing\n")).to eq("As he wrote:\nnothing\n")
  end

  it "stops at a forwarded original" do
    expect(strip("Top.\n-----Original Message-----\nFrom: x\nold\n")).to eq("Top.\n")
  end

  it "squeezes the blank lines the removed parts leave" do
    expect(strip("a\n\n> q\n\n> q\n\nb\n")).to eq("a\n\nb\n")
  end

  it "takes nil and broken bytes" do
    expect(strip(nil)).to eq("")
    expect(strip("ok \xFF\n> q\n".dup.force_encoding("UTF-8"))).to eq("ok \uFFFD\n")
  end
end
