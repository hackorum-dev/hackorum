require "rails_helper"

RSpec.describe Lineage::References do
  let(:topic) { create(:topic) }
  let!(:m1) { create(:message, topic: topic, created_at: 2.days.ago) }
  let!(:m2) { create(:message, topic: topic, created_at: 1.day.ago) }
  let(:sha) { "72b6ad63" + "0" * 32 }

  def normalize(text, shas: [ sha ])
    described_class.normalize(text, topic: topic, shas: shas.to_set)
  end

  it "rewrites message ids and known shas" do
    expect(normalize("see message #{m1.id} and #{sha} (Message #{m2.id})"))
      .to eq("see [msg:#{m1.id}] and [commit:#{sha}] ([msg:#{m2.id}])")
  end

  it "maps messages/NNN.txt ordinals to ids" do
    expect(normalize("per messages/2.txt and messages/1.txt")).to eq("per [msg:#{m2.id}] and [msg:#{m1.id}]")
  end

  it "treats message #N as an ordinal, not an id" do
    expect(normalize("message #2, messages #1, Message#2")).to eq("[msg:#{m2.id}], [msg:#{m1.id}], [msg:#{m2.id}]")
    expect(normalize("message ##{m1.id}")).to eq("message ##{m1.id}")
  end

  it "leaves unknown ids, ordinals and shas alone" do
    other = create(:message)
    text = "message #{other.id}, messages/9.txt, messages/0.txt, message #9, #{'a' * 40}, #{sha}0"
    expect(normalize(text)).to eq(text)
  end

  it "leaves shas inside urls alone" do
    text = "commitdiff;h=#{sha} and https://x/commit/#{sha}"
    expect(normalize(text)).to eq(text)
  end

  it "keeps existing tokens untouched" do
    text = "[msg:#{m1.id}] [commit:#{sha}] message 12345678901"
    expect(normalize(text)).to eq(text)
  end

  it "leaves topic tokens alone" do
    expect(normalize("see [topic:123] and [topic:7]")).to eq("see [topic:123] and [topic:7]")
  end

  it "downcases matched shas" do
    expect(normalize(sha.upcase)).to eq("[commit:#{sha}]")
  end

  it "passes blank text through" do
    expect(normalize("")).to eq("")
    expect(normalize(nil)).to be_nil
  end
end
