require "rails_helper"
require "rake"

RSpec.describe "classify:requeue_failed" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["classify:requeue_failed"] }

  before { task.reenable }

  it "deletes failed and timed out runs of one topic or all" do
    a = create(:topic)
    b = create(:topic)
    done = create(:classification_run, topic: a)
    create(:classification_run, topic: a, status: "failed")
    create(:classification_run, topic: b, status: "timeout")
    claimed = create(:classification_run, topic: b, status: "claimed", claimed_at: Time.current)

    expect { task.invoke(a.id.to_s) }.to output("1\n").to_stdout
    expect(ClassificationRun.where(topic: b).count).to eq(2)
    task.reenable
    expect { task.invoke }.to output("1\n").to_stdout
    expect(ClassificationRun.pluck(:id)).to contain_exactly(done.id, claimed.id)
  end
end
