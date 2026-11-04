require "rails_helper"

RSpec.describe Topics::ParticipantActivity do
  let(:msg) { Struct.new(:id, :sender_person_id) }

  def person(*types)
    create(:person).tap do |p|
      types.each { |t| ContributorMembership.create!(person: p, contributor_type: t) }
    end
  end

  def participant(person, count)
    { person: person.reload, message_count: count, alias: nil }
  end

  let(:korotkov) { person("committer", "major_contributor") }
  let(:lakhin) { person("major_contributor") }
  let(:jian) { person("significant_contributor") }
  let(:koval) { person }
  let(:past) { person("past_major_contributor") }

  let(:participants) do
    [ participant(koval, 93), participant(korotkov, 66), participant(jian, 37),
      participant(lakhin, 16), participant(past, 2) ]
  end

  let(:messages) do
    [ msg.new(1, koval.id), msg.new(2, korotkov.id), msg.new(3, jian.id), msg.new(4, koval.id) ]
  end

  def activity(viewer_person_id: nil, list: participants, msgs: messages)
    described_class.new(participants: list, messages: msgs,
                        message_numbers: msgs.to_h { |m| [ m.id, m.id ] },
                        viewer_person_id: viewer_person_id)
  end

  it "buckets each person once by highest role" do
    buckets = activity.buckets.to_h { |b| [ b.key, [ b.people, b.messages ] ] }

    expect(buckets).to eq(committers: [ 1, 66 ], major: [ 1, 16 ], significant: [ 1, 37 ], others: [ 2, 95 ])
    expect(activity.total_messages).to eq(214)
  end

  it "finds the last committer message" do
    last = activity.last_committer_message
    expect(last[:number]).to eq(2)
    expect(last[:message].id).to eq(2)
  end

  it "pins the viewer only outside the top 5" do
    me = person
    list = participants + [ participant(me, 1) ]
    msgs = messages + [ msg.new(5, me.id) ]

    a = activity(viewer_person_id: me.id, list: list, msgs: msgs)
    expect(a.viewer[:person]).to eq(me)
    expect(a.viewer_last_number).to eq(5)
    expect(a.rest.map { |p| p[:person] }).not_to include(me)

    expect(activity(viewer_person_id: koval.id).viewer).to be_nil
    expect(activity.viewer).to be_nil
  end

  it "labels a participant's bucket" do
    expect(activity.bucket_label(participants[1])).to eq("Committers")
    expect(activity.bucket_label(participants[0])).to eq("Others")
  end
end
