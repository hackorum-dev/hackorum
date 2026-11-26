class ReserveBotUsername < ActiveRecord::Migration[8.0]
  # held for the system until Classify::Setup creates the bot
  def up
    execute <<~SQL.squish
      INSERT INTO name_reservations (name, owner_type, owner_id, created_at, updated_at)
      SELECT 'hackorum-bot', 'System', 0, now(), now()
      WHERE NOT EXISTS (SELECT 1 FROM name_reservations WHERE name = 'hackorum-bot')
        AND NOT EXISTS (SELECT 1 FROM users WHERE lower(username) = 'hackorum-bot')
    SQL
  end

  def down
    execute "DELETE FROM name_reservations WHERE name = 'hackorum-bot' AND owner_type = 'System' AND owner_id = 0"
  end
end
