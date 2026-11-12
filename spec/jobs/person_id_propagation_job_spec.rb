require "rails_helper"

RSpec.describe PersonIdPropagationJob do
  let(:old_person) { create(:person) }
  let(:new_person) { create(:person) }
  let(:moved) { create(:alias, person: old_person) }
  let(:kept) { create(:alias, person: old_person) }
  let(:topic) { create(:topic, creator_alias: kept) }

  it "moves the messages of the alias and the author of their feed events" do
    moved_message = create(:message, topic: topic, sender_alias: moved)
    kept_message = create(:message, topic: topic, sender_alias: kept)
    branch = create(:patch_branch, topic: topic, message: moved_message)
    [ moved_message, kept_message ].each { |message| FeedEvents::Recorder.message_received(message) }
    FeedEvents::Recorder.branch_created(branch)
    FeedEvents::Recorder.ci_completed(create(:patch_ci_run, patch_branch: branch, status: "success"))
    moved.update_columns(person_id: new_person.id)

    described_class.perform_now(moved.id, new_person.id, old_person.id)

    expect(moved_message.reload.sender_person_id).to eq(new_person.id)
    expect(kept_message.reload.sender_person_id).to eq(old_person.id)
    expect(FeedEvent.where(message_id: moved_message.id).pluck(:event_type, :author_person_id))
      .to contain_exactly([ "message.received", new_person.id ], [ "branch.created", new_person.id ],
                          [ "ci.completed", new_person.id ])
    expect(FeedEvent.where(message_id: kept_message.id).pluck(:author_person_id)).to eq([ old_person.id ])
  end

  it "fixes events whose messages were moved before" do
    message = create(:message, topic: topic, sender_alias: moved)
    FeedEvents::Recorder.message_received(message)
    moved.update_columns(person_id: new_person.id)
    message.update_columns(sender_person_id: new_person.id)

    described_class.perform_now(moved.id, new_person.id, old_person.id)

    expect(FeedEvent.sole.author_person_id).to eq(new_person.id)
  end
end
