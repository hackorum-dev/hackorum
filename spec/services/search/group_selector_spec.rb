require "rails_helper"

RSpec.describe "Search group: selector", type: :service do
  let(:parser) { Search::QueryParser.new }
  let(:user) { create(:user) }

  def build_query(query_string)
    ast = parser.parse(query_string)
    validated = Search::QueryValidator.new(ast).validate
    Search::QueryBuilder.new(ast: validated.ast, user: user).build
  end

  def ids(query)
    build_query(query).relation.pluck(:id)
  end

  let!(:group) { create(:feature_group, name: "Incremental Backup") }
  let!(:grouped) { create(:topic) }
  let!(:orphan_row) { create(:topic) }
  let!(:ungrouped) { create(:topic) }

  before do
    create(:feature_group_topic, feature_group: group, topic: grouped)
    create(:feature_group_topic, feature_group: nil, topic: orphan_row)
  end

  it "finds by slug" do
    expect(ids("group:#{group.slug}")).to contain_exactly(grouped.id)
  end

  it "finds by name in other case" do
    expect(ids('group:"incremental BACKUP"')).to contain_exactly(grouped.id)
  end

  it "resolves a merged group to the survivor" do
    old = create(:feature_group, name: "Old name")
    old.merge_into!(group)
    expect(ids("group:#{old.slug}")).to contain_exactly(grouped.id)
  end

  it "unknown group matches nothing with a warning, negated everything" do
    result = build_query("group:nonexistent")
    expect(result.relation.pluck(:id)).to be_empty
    expect(result.warnings.join).to include("Unknown group 'nonexistent'")
    expect(ids("-group:nonexistent")).to include(grouped.id, orphan_row.id, ungrouped.id)
  end

  it "has:group excludes null-group rows and ungrouped topics" do
    result = ids("has:group")
    expect(result).to contain_exactly(grouped.id)
  end

  it "-has:group includes the others" do
    expect(ids("-has:group")).to include(orphan_row.id, ungrouped.id)
  end
end
