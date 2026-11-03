require "rails_helper"

RSpec.describe CommitTopic do
  it "defaults to trailer and scopes by source" do
    trailer = create(:commit_topic)
    llm = create(:commit_topic, source: "llm", confidence: 0.9)

    expect(trailer.source).to eq("trailer")
    expect(described_class.trailer).to contain_exactly(trailer)
    expect(described_class.llm).to contain_exactly(llm)
  end

  it "rejects unknown sources" do
    expect(build(:commit_topic, source: "guess")).not_to be_valid
  end
end
