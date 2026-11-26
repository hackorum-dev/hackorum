require "rails_helper"
require "open3"

RSpec.describe "script/lineage_processor.rb" do
  def run(*args)
    env = { "LINEAGE_SERVER" => nil, "LINEAGE_API_TOKEN" => nil }
    Open3.capture3(env, RbConfig.ruby, Rails.root.join("script/lineage_processor.rb").to_s,
                   "--server", "http://127.0.0.1:9", "--token", "t", "--limit", "0", *args)
  end

  it "runs classify without --model and --effort" do
    _, err, = run("--work", "classify")
    expect(err).not_to include("--model")
  end
end
