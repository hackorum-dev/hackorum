class AddByteSizeToAttachments < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  BATCH = 5000

  def up
    add_column :attachments, :byte_size, :integer unless column_exists?(:attachments, :byte_size)

    first, last = select_rows("SELECT MIN(id), MAX(id) FROM attachments").first
    fallback_rows = 0
    if first
      say_with_time "backfill attachments.byte_size, ids #{first}..#{last}" do
        (first..last).step(BATCH) { |from| fallback_rows += backfill(from, from + BATCH - 1) }
        # rows added while the batches ran
        fallback_rows += backfill(last + 1, nil)
        nil
      end
    end
    say "#{fallback_rows} rows sized in Ruby", true

    change_column_default :attachments, :byte_size, 0
    change_column_null :attachments, :byte_size, false
  end

  def down
    remove_column :attachments, :byte_size
  end

  private

  def backfill(from, to)
    range = to ? "id BETWEEN #{from} AND #{to}" : "id >= #{from}"
    execute(<<~SQL.squish)
      UPDATE attachments SET byte_size = COALESCE(octet_length(decode(body, 'base64')), 0)
      WHERE #{range} AND byte_size IS NULL
    SQL
    0
  rescue ActiveRecord::StatementInvalid => e
    say "ids #{from}..#{to}: #{e.message.lines.first.strip}, sizing in Ruby", true
    rows = select_rows("SELECT id, body FROM attachments WHERE #{range} AND byte_size IS NULL")
    rows.each do |id, body|
      execute("UPDATE attachments SET byte_size = #{Base64.decode64(body.to_s).bytesize} WHERE id = #{id}")
    end
    rows.size
  end
end
