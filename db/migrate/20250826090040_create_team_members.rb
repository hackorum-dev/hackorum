# frozen_string_literal: true

class CreateTeamMembers < ActiveRecord::Migration[7.1]
  def change
    create_enum :team_member_role, %w[member admin]

    create_table :team_members do |t|
      t.references :team, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.enum :role, enum_type: "team_member_role", null: false, default: "member"

      t.timestamps
    end

    add_index :team_members, [ :team_id, :user_id ], unique: true
  end
end
