# frozen_string_literal: true

class AddMetricsToImapSyncStates < ActiveRecord::Migration[7.1]
  def change
    change_table :imap_sync_states, bulk: true do |t|
      t.datetime :last_cycle_started_at
      t.integer  :last_cycle_duration_ms
      t.integer  :last_fetched_count
      t.integer  :last_ingested_count
      t.integer  :last_duplicate_count
      t.integer  :last_attachment_count
      t.integer  :last_patch_files_count
      t.integer  :last_backlog_count
      t.integer  :consecutive_error_count, null: false, default: 0
      t.string   :last_error_class
      t.integer  :backoff_seconds
    end
  end
end
