namespace :staging do
  desc "Neutralize restored prod state on staging: queued jobs, in-flight sends, IMAP positions"
  task sanitize: :environment do
    unless Hackorum.staging?
      $stderr.puts "staging:sanitize refuses to run unless HACKORUM_ENV=staging"
      exit 1
    end

    drafts = OutgoingDraft.sending.update_all(
      status: OutgoingDraft::STATUS_IDLE,
      last_send_error: "Reset by staging restore",
      sending_started_at: nil,
      updated_at: Time.current
    )

    sync_states = ImapSyncState.delete_all

    conn = SolidQueue::Record.connection
    tables = conn.tables.grep(/\Asolid_queue_/)
    jobs = SolidQueue::Job.table_exists? ? SolidQueue::Job.count : 0
    conn.execute("TRUNCATE #{tables.map { |t| conn.quote_table_name(t) }.join(', ')} RESTART IDENTITY CASCADE") if tables.any?

    puts "staging:sanitize drafts=#{drafts} sync_states=#{sync_states} jobs=#{jobs}"
  end
end
