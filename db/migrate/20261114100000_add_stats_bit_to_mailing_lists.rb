class AddStatsBitToMailingLists < ActiveRecord::Migration[8.0]
  def up
    add_column :mailing_lists, :stats_bit, :integer, limit: 2
    execute <<~SQL
      UPDATE mailing_lists SET stats_bit = n.bit
      FROM (SELECT id, row_number() OVER (ORDER BY id) - 1 AS bit FROM mailing_lists) n
      WHERE n.id = mailing_lists.id
    SQL
    add_index :mailing_lists, :stats_bit, unique: true
  end

  def down
    remove_column :mailing_lists, :stats_bit
  end
end
