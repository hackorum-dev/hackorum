# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonSplitService do
  let(:person) { create(:person) }
  let!(:bruce) { create(:alias, person: person, name: "Bruce Momjian", email: "bruce@momjian.us") }
  let!(:greg) { create(:alias, person: person, name: "Greg Stark", email: "stark@mit.edu") }
  let!(:greg_caps) { create(:alias, person: person, name: "Gregory Stark", email: "Stark@MIT.edu ") }

  def split(emails: [ "stark@mit.edu" ], membership_ids: [])
    described_class.new(person: person, emails: emails, membership_ids: membership_ids).call
  end

  it "moves every alias of the emails, in any case, to a new person" do
    result = split

    expect(result.success?).to be true
    new_person = result.person
    expect(greg.reload.person_id).to eq(new_person.id)
    expect(greg_caps.reload.person_id).to eq(new_person.id)
    expect(bruce.reload.person_id).to eq(person.id)
  end

  it "moves topics, messages and mentions of the moved aliases" do
    topic = create(:topic, creator_alias: greg)
    greg_msg = create(:message, topic: topic, sender_alias: greg)
    bruce_msg = create(:message, topic: topic, sender_alias: bruce)
    mention = create(:mention, message: bruce_msg, alias: greg)
    topic.recalculate_participants!

    new_person = split.person

    expect(topic.reload.creator_person_id).to eq(new_person.id)
    expect(greg_msg.reload.sender_person_id).to eq(new_person.id)
    expect(bruce_msg.reload.sender_person_id).to eq(person.id)
    expect(mention.reload.person_id).to eq(new_person.id)
    expect(topic.topic_participants.pluck(:person_id)).to contain_exactly(person.id, new_person.id)
  end

  it "moves commit credits of the emails and clears name-only ones for a relink" do
    by_email = create(:commit_person, person: person, raw_name: "Greg Stark", raw_email: "stark@mit.edu")
    by_name = create(:commit_person, person: person, raw_name: "Bruce Momjian", raw_email: nil)
    kept = create(:commit_person, person: person, raw_name: "Bruce Momjian", raw_email: "bruce@momjian.us")

    new_person = split.person

    expect(by_email.reload.person_id).to eq(new_person.id)
    expect(by_name.reload.person_id).to be_nil
    expect(kept.reload.person_id).to eq(person.id)
  end

  it "resyncs committer reviewer rows of the moved credits" do
    commit = create(:commit)
    create(:commit_person, commit: commit, person: person, role: "committer", raw_name: "Bruce Momjian", raw_email: "bruce@momjian.us")
    create(:commit_person, commit: commit, person: person, role: "author", raw_name: "Greg Stark", raw_email: "stark@mit.edu")
    CommitterReviewer.sync!([ commit.id ])
    expect(CommitPerson.committer_sourced.where(commit: commit)).to be_empty

    split

    expect(CommitPerson.committer_sourced.where(commit: commit).pluck(:person_id, :raw_name)).to eq([ [ person.id, "Bruce Momjian" ] ])
  end

  it "moves only the given contributor memberships" do
    greg_membership = ContributorMembership.create!(person: person, contributor_type: "significant_contributor")
    bruce_membership = ContributorMembership.create!(person: person, contributor_type: "core_team")

    new_person = split(membership_ids: [ greg_membership.id ]).person

    expect(greg_membership.reload.person_id).to eq(new_person.id)
    expect(bruce_membership.reload.person_id).to eq(person.id)
  end

  it "sets default aliases on both sides" do
    new_person = split.person

    expect(new_person.reload.default_alias.email.downcase.strip).to eq("stark@mit.edu")
    expect(person.reload.default_alias).to eq(bruce)
  end

  it "refuses to move every alias" do
    result = split(emails: [ "stark@mit.edu", "bruce@momjian.us" ])

    expect(result.success?).to be false
    expect(greg.reload.person_id).to eq(person.id)
  end

  it "refuses to move aliases claimed by a user account" do
    greg.update!(user: create(:user, person: person))

    result = split

    expect(result.success?).to be false
    expect(greg.reload.person_id).to eq(person.id)
  end
end
