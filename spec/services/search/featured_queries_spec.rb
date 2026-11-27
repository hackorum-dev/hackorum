require "rails_helper"

RSpec.describe "Featured and guide search queries", type: :service do
  let(:user) { create(:user) }

  before { create(:alias, name: "tom", email: "tom@example.org") }

  featured = [
    "tag:bug -tag:not-a-bug -has:commit",
    "has:patch[waiting:any]",
    "has:patch[after:me]"
  ].freeze

  guide_examples = [
    "commit:[reviewer:me, released:19]",
    "ci:failing has:patch[from:me]",
    "apply:needs_rebase from:me",
    "has:later_fix commit:[released:18]",
    "-has:commit has:patch",
    "has:fixes -has:later_fix",
    "ci:pending -apply:wont_retry",
    "has:patch[waiting:1m]",
    "has:patch participants:1",
    "commit:[committer:tom, committed_after:1y]",
    "commit:[author:me, released:none]",
    "commit:3f2a9c1",
    "tag:feature tag:major",
    "tag:performance has:patch[waiting:any]",
    "-has:group tag:feature",
    "list:bugs has:patch"
  ].freeze

  def run_query(query)
    ast = Search::QueryParser.new.parse(query)
    validated = Search::QueryValidator.new(ast).validate
    built = Search::QueryBuilder.new(ast: validated.ast, user: user).build
    [ validated.warnings + built.warnings, built.relation ]
  end

  (featured + guide_examples).each do |query|
    it "runs '#{query}' without warnings" do
      warnings, relation = run_query(query)

      expect(warnings).to be_empty
      expect { relation.to_a }.not_to raise_error
    end
  end
end
