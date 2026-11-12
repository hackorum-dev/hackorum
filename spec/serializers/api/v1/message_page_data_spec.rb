require "rails_helper"

RSpec.describe Api::V1::MessagePageData do
  let(:user) { create(:user) }
  let(:sender) { create(:alias) }

  it "tests a message against the read ranges of its own topic only" do
    first, second = Array.new(2) { create(:topic, creator_alias: sender) }
    before = create(:message, topic: first, sender: sender)
    between = create(:message, topic: second, sender: sender)
    after = create(:message, topic: first, sender: sender)
    outside = create(:message, topic: second, sender: sender)
    MessageReadRange.add_range(user: user, topic: first, start_id: before.id, end_id: after.id)
    MessageReadRange.add_range(user: user, topic: second, start_id: outside.id, end_id: outside.id)
    expect(between.id).to be_between(before.id, after.id)

    data = described_class.new([ before, between, after, outside ], user: user)

    expect([ before, between, after, outside ].map { |message| data.me(message.id) })
      .to eq([ { read: true }, { read: false }, { read: true }, { read: true } ])
  end

  it "gives no state without a user" do
    message = create(:message, topic: create(:topic, creator_alias: sender), sender: sender)

    expect(described_class.new([ message ]).me(message.id)).to be_nil
  end
end
