require "rails_helper"

RSpec.describe CommitVerdict do
  it "treats as_is, modified, partial and from_discussion as committed" do
    committed = %w[as_is modified partial from_discussion].map { |v| build(:commit_verdict, verdict: v) }
    others = %w[not_this_thread undecided].map { |v| build(:commit_verdict, verdict: v) }

    expect(committed).to all(be_committed)
    expect(others).to all(satisfy { |v| !v.committed? })
  end

  it "defaults origin to trailer and rejects unknown origins" do
    expect(build(:commit_verdict).origin).to eq("trailer")
    expect(build(:commit_verdict, origin: "extra")).to be_valid
    expect(build(:commit_verdict, origin: "guess")).not_to be_valid
  end

  it "carries the model-named author and its message, both optional" do
    expect(build(:commit_verdict)).to have_attributes(author_name: nil, author_message: nil)
    message = create(:message)
    verdict = create(:commit_verdict, author_name: "Carol", author_message: message)
    expect(verdict.reload).to have_attributes(author_name: "Carol", author_message_id: message.id)
  end

  it "allows a nil change_level but rejects unknown levels" do
    expect(build(:commit_verdict, change_level: nil)).to be_valid
    expect(build(:commit_verdict, change_level: "moderate")).to be_valid
    expect(build(:commit_verdict, change_level: "huge")).not_to be_valid
  end
end
