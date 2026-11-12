require "rails_helper"

RSpec.describe Api::V1::TopicLookup do
  let(:context) { Api::V1::Context.new(user: nil, token: nil, base_url: "https://hackorum.example") }

  def moved(path, query = "")
    described_class.moved_url(context, path: path, query: query, id: 42)
  end

  it "swaps the topic segment" do
    expect(moved("/api/v1/topics/7")).to eq("https://hackorum.example/api/v1/topics/42")
    expect(moved("/api/v1/topics/old-name.1")).to eq("https://hackorum.example/api/v1/topics/42")
  end

  it "keeps the rest of the path" do
    expect(moved("/api/v1/topics/7/messages")).to eq("https://hackorum.example/api/v1/topics/42/messages")
    expect(moved("/api/v1/topics/old-name/patchsets/3")).to eq("https://hackorum.example/api/v1/topics/42/patchsets/3")
  end

  it "keeps the query string" do
    expect(moved("/api/v1/topics/7/commits", "limit=5&cursor=abc"))
      .to eq("https://hackorum.example/api/v1/topics/42/commits?limit=5&cursor=abc")
    expect(moved("/api/v1/topics/7", nil)).to eq("https://hackorum.example/api/v1/topics/42")
  end

  it "falls back to the topic itself for a path it does not know" do
    expect(moved("/elsewhere/7/messages")).to eq("https://hackorum.example/api/v1/topics/42")
    expect(moved("//evil.example/api/v1/topics/7")).to eq("https://hackorum.example/api/v1/topics/42")
  end
end
