module StatsListsFixture
  def build_stats_lists_fixture
    hackers = create(:mailing_list, identifier: "pgsql-hackers")
    general = create(:mailing_list, identifier: "pgsql-general")
    committers = create(:mailing_list, identifier: "pgsql-committers", hidden_by_default: true)
    aliases = %i[ann bob carl cora dan].index_with { |n| create(:alias, name: n.to_s.capitalize) }
    ContributorMembership.create!(person: aliases[:cora].person, contributor_type: "major_contributor")
    ContributorMembership.create!(person: aliases[:dan].person, contributor_type: "major_contributor")
    commit = create(:commit, committed_at: Time.utc(2024, 2, 1, 12))
    create(:commit_person, commit: commit, person: aliases[:carl].person, role: "committer")
    dan_commit = create(:commit, committed_at: Time.utc(2023, 6, 1, 12))
    create(:commit_person, commit: dan_commit, person: aliases[:dan].person, role: "committer")
    t1, t2, t3, t4, t5 = create_list(:topic, 5)

    msg = lambda do |who, topic, at, lists, patch: false, state: Message::STATE_SENT|
      m = create(:message, sender: aliases[who], topic: topic, created_at: at, updated_at: at,
                           is_patch_submission: patch, state: state)
      lists.each { |l| create(:message_mailing_list, message: m, mailing_list: l) }
      m
    end

    messages = {
      m0: msg.(:dan, t5, Time.utc(2023, 12, 1, 10), [ hackers ]),
      m8: msg.(:cora, t4, Time.utc(2024, 1, 2, 10), [ committers ]),
      m1: msg.(:ann, t1, Time.utc(2024, 1, 3, 10), [ hackers ], patch: true),
      pending: msg.(:ann, t1, Time.utc(2024, 1, 3, 11), [ hackers ], state: Message::STATE_PENDING),
      m2: msg.(:carl, t1, Time.utc(2024, 1, 4, 10), [ hackers ]),
      unlisted: msg.(:bob, t1, Time.utc(2024, 1, 4, 11), []),
      m3: msg.(:bob, t2, Time.utc(2024, 1, 5, 10), [ general ]),
      m4: msg.(:cora, t2, Time.utc(2024, 1, 5, 12), [ hackers, general ]),
      m5: msg.(:carl, t1, Time.utc(2024, 2, 7, 10), [ hackers ]),
      m6: msg.(:bob, t3, Time.utc(2024, 2, 8, 10), [ hackers ]),
      m7: msg.(:ann, t1, Time.utc(2024, 3, 15, 10), [ hackers ])
    }
    { lists: { hackers: hackers, general: general, committers: committers },
      people: aliases.transform_values(&:person), messages: messages }
  end
end

RSpec.configure do |config|
  config.include StatsListsFixture
end
