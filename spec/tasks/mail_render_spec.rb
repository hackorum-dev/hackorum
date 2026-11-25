require "rails_helper"
require "rake"

RSpec.describe "mail:render" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["mail:render"] }

  before { task.reenable }

  it "prints skipped" do
    allow(MailConfig::Renderer).to receive(:call).and_return(:skipped)
    expect { task.invoke }.to output("skipped\n").to_stdout
  end

  it "prints unchanged" do
    allow(MailConfig::Renderer).to receive(:call).and_return([])
    expect { task.invoke }.to output("unchanged\n").to_stdout
  end

  it "prints written files" do
    allow(MailConfig::Renderer).to receive(:call).and_return(%w[a.cf b.map])
    expect { task.invoke }.to output("a.cf b.map\n").to_stdout
  end

  it "aborts on a missing fragment" do
    allow(MailConfig::Renderer).to receive(:call).and_raise(MailConfig::Renderer::MissingFragment, "nope")
    expect { task.invoke }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      .and output("nope\n").to_stderr
  end
end
