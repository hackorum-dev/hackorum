require "rails_helper"

RSpec.describe Lineage::ThreadRank do
  it "orders patch threads by latest patch mail, then no-patch threads by id" do
    bug = create(:topic).tap { |t| create(:message, topic: t) }
    old = create(:topic).tap { |t| create(:message, topic: t, is_patch_submission: true, created_at: 3.days.ago) }
    new = create(:topic).tap { |t| create(:message, topic: t, is_patch_submission: true, created_at: 1.day.ago) }
    bug2 = create(:topic).tap { |t| create(:message, topic: t) }
    expect(described_class.order([ bug2.id, bug.id, old.id, new.id ])).to eq([ new.id, old.id, bug.id, bug2.id ])
  end
end
