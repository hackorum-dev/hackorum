require "rails_helper"
require Rails.root.join("script/affiliations/generate")
require Rails.root.join("script/affiliations/import")

RSpec.describe "affiliation scripts" do
  let(:dir) { Dir.mktmpdir }
  after { FileUtils.rm_rf(dir) }

  def sender(name, email, count: 1)
    create(:alias, name: name, email: email, sender_count: count)
  end

  def generated
    CSV.read("#{dir}/out.csv", headers: true).map { |r| [ r["person_id"].to_i, r["company"], r["source"] ] }
  end

  it "generates candidates from memberships and domains, then imports them" do
    a = sender("Ann", "ann@enterprisedb.com")
    ContributorMembership.create!(person: a.person, contributor_type: "committer", company: "EDB")
    sender("Ben", "ben@gmail.com")
    c = sender("Cat", "cat@enterprisedb.com")
    sender("Dan", "dan@enterprisedb.com", count: 0)
    File.write("#{dir}/domains.yml", "enterprisedb.com: EDB\n")

    n = AffiliationGenerate.write("#{dir}/out.csv", "#{dir}/domains.yml")
    expect(n).to eq(2)
    expect(generated).to eq([ [ a.person.id, "EDB", "contributors_page" ], [ c.person.id, "EDB", "domain" ] ])
    expect(PersonAffiliation.count).to eq(0)

    expect(AffiliationImport.apply("#{dir}/out.csv", dry_run: true)).to eq(2)
    expect(PersonAffiliation.count).to eq(0)
    AffiliationImport.apply("#{dir}/out.csv")
    AffiliationImport.apply("#{dir}/out.csv")
    expect(PersonAffiliation.where(person: a.person).pluck(:company, :source)).to eq([ [ "EDB", "contributors_page" ] ])
    expect(PersonAffiliation.count).to eq(2)
  end

  it "matches subdomains and skips excluded people" do
    f = sender("Fum", "fum@jp.fujitsu.com")
    g = sender("Gus", "gus@fujitsu.com")
    File.write("#{dir}/domains.yml", "fujitsu.com: \" Fujitsu \"\n")
    File.write("#{dir}/exclude.txt", "#{g.person.id}\n")

    AffiliationGenerate.write("#{dir}/out.csv", "#{dir}/domains.yml", "#{dir}/exclude.txt")
    expect(generated).to eq([ [ f.person.id, "Fujitsu", "domain" ] ])
  end

  it "reads percona-pg-activity's mappings, dates employer changes and normalizes company names" do
    File.write("#{dir}/percona_activity.py", <<~PY)
      MANUAL_IDENTITIES: dict[str, list[str]] = {
          "Andreas Karlsson": ["andreas@proxel.se"],
      }
      COMPANY_DOMAINS: dict[str, str] = {
          "enterprisedb.com": "EDB",
          "Amazon.com": "Amazon",   # trailing comment
      }
      COMPANY_NAME_OVERRIDES: dict[str, str] = {
          "robert haas": "EDB",
          "tom lane": "Snowflake",
          "masahiko sawada": "Amazon",
      }
      NAME_ALIASES: dict[str, str] = {
          "sawada masahiko": "masahiko sawada",
      }
      COMPANY_NAME_HISTORY: dict[str, list[tuple[str, str]]] = {
          "robert haas": [("2026-09-01", "Databricks")],   # EDB until 2026-08
      }
    PY
    rob = sender("Robert Haas", "rhaas@gmail.com")
    tom = sender("Tom Lane", "tgl@sss.pgh.pa.us")
    tom2 = sender("Tom Lane", "tom@example.org")
    saw = sender("Sawada Masahiko", "sawada@example.com")
    ann = sender("Ann", "ann@amazon.com")
    ContributorMembership.create!(person: ann.person, contributor_type: "committer", company: "Amazon Web Services (RDS Open Source Databases)")
    neon = sender("Nia", "nia@example.net")
    ContributorMembership.create!(person: neon.person, contributor_type: "committer", company: "Neon, Inc.")
    File.write("#{dir}/domains.yml", "amazon.com: Amazon Web Services\n")

    AffiliationGenerate.write("#{dir}/out.csv", "#{dir}/domains.yml", percona_path: "#{dir}/percona_activity.py")
    rows = CSV.read("#{dir}/out.csv", headers: true).map { |r| [ r["person_id"].to_i, r["company"], r["since"], r["until"], r["source"], r["note"] ] }
    expect(rows).to contain_exactly(
      [ ann.person.id, "Amazon", nil, nil, "contributors_page", nil ],
      [ neon.person.id, "Neon", nil, nil, "contributors_page", nil ],
      [ rob.person.id, "EDB", nil, "2026-08-31", "manual", nil ],
      [ rob.person.id, "Databricks", "2026-09-01", nil, "manual", nil ],
      [ tom.person.id, "Snowflake", nil, nil, "manual", "name matches 2 people" ],
      [ tom2.person.id, "Snowflake", nil, nil, "manual", "name matches 2 people" ],
      [ saw.person.id, "Amazon", nil, nil, "manual", nil ]
    )

    AffiliationImport.apply("#{dir}/out.csv")
    affiliations = Stats::Affiliations.new([ rob.person.id, ann.person.id ])
    expect(affiliations.company_for(rob.person.id, Date.new(2026, 8, 1))).to eq("EDB")
    expect(affiliations.company_for(rob.person.id, Date.new(2026, 9, 1))).to eq("Databricks")
    expect(affiliations.company_for(ann.person.id, Date.new(2026, 9, 1))).to eq("Amazon")

    File.write("#{dir}/one.csv", "person_id,company,since,until,source\n#{rob.person.id},Acme,,,manual\n")
    AffiliationImport.apply("#{dir}/one.csv", replace: true)
    expect(PersonAffiliation.pluck(:person_id, :company)).to eq([ [ rob.person.id, "Acme" ] ])
  end

  it "refuses invalid and duplicate rows, dry run included" do
    p = create(:person)
    File.write("#{dir}/bad.csv", "person_id,company,since,until,source\n#{p.id},Acme,,,guess\n")
    expect { AffiliationImport.apply("#{dir}/bad.csv", dry_run: true) }.to raise_error(ArgumentError, /Source/)
    File.write("#{dir}/dup.csv", "person_id,company,since,until,source\n#{p.id},Acme,,,manual\n#{p.id},Acme,,,domain\n")
    expect { AffiliationImport.apply("#{dir}/dup.csv") }.to raise_error(ArgumentError, /duplicate/)
    expect(PersonAffiliation.count).to eq(0)
  end
end
