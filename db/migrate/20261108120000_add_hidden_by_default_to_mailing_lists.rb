class AddHiddenByDefaultToMailingLists < ActiveRecord::Migration[8.0]
  # the backfill must not hold the add_column lock on topics
  disable_ddl_transaction!

  def up
    add_column :mailing_lists, :hidden_by_default, :boolean, null: false, default: false
    add_column :topics, :hidden_by_default, :boolean, null: false, default: false

    execute <<~SQL
      UPDATE mailing_lists
      SET hidden_by_default = true,
          display_name = CASE WHEN display_name = 'comitters' THEN 'committers' ELSE display_name END
      WHERE identifier = 'pgsql-committers'
    SQL

    execute <<~SQL
      UPDATE topics SET hidden_by_default = true
      WHERE id IN (
        SELECT tml.topic_id
        FROM topic_mailing_lists tml
        JOIN mailing_lists ml ON ml.id = tml.mailing_list_id
        GROUP BY tml.topic_id
        HAVING bool_and(ml.hidden_by_default)
      )
    SQL
  end

  def down
    remove_column :topics, :hidden_by_default
    remove_column :mailing_lists, :hidden_by_default
  end
end
