class SeedParsedDataSavedSearches < ActiveRecord::Migration[8.0]
  SEARCHES = [
    [ "Bug reports without commits", "tag:bug -tag:not-a-bug -has:commit", "global", 2 ],
    [ "Patch waiting for review", "has:patch[waiting:any]", "global", 3 ],
    [ "New patch since I posted", "has:patch[after:me]", "user", 5 ]
  ].freeze

  def up
    SEARCHES.each do |name, query, scope, position|
      SavedSearch.find_or_create_by!(name: name, scope: scope, user_id: nil, team_id: nil) do |s|
        s.query = query
        s.position = position
      end
    end
  end

  def down
    SavedSearch.where(name: SEARCHES.map(&:first), user_id: nil, team_id: nil).destroy_all
  end
end
