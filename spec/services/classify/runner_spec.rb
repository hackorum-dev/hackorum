require "rails_helper"

RSpec.describe Classify do
  it "defaults to sol at medium effort" do
    runner = described_class.runner
    expect([ runner.model, runner.effort ]).to eq([ "gpt-6.2-sol", "medium" ])
  end

  it "builds a read-only stdin runner" do
    runner = described_class.runner(model: "m", effort: "low", codex_bin: "codex")
    cmd = runner.command("/j")
    expect(cmd).to include("read-only", Rails.root.join("config/classify/result.schema.json").to_s, "-m", "m")
    expect(cmd.last).to start_with("Classify the mailing list thread")
    expect(Classify::NoopCompleter.call("/j")).to be_nil
  end
end
