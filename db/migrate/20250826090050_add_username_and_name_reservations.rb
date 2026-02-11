# frozen_string_literal: true

class AddUsernameAndNameReservations < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :username, :string
    add_index :users, :username, unique: true

    create_table :name_reservations do |t|
      t.string :name, null: false
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      t.timestamps
    end

    add_index :name_reservations, :name, unique: true
    add_index :name_reservations, [ :owner_type, :owner_id ]
  end
end
