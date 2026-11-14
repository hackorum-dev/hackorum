require "rails_helper"

RSpec.describe TopicLink do
  it "has a valid factory" do
    expect(build(:topic_link)).to be_valid
  end

  it "rejects unknown kind and direction" do
    expect(build(:topic_link, kind: "x")).not_to be_valid
    expect(build(:topic_link, direction: "x")).not_to be_valid
  end
end
