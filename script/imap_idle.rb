#!/usr/bin/env ruby
# frozen_string_literal: true

#
# IMAP IDLE runner for continuous Gmail ingestion
#
# Description
# - Long-lived process that connects to Gmail IMAP, performs an initial catch-up,
#   then waits using IDLE for new messages. New UIDs are fetched, ingested via
#   EmailIngestor, and marked as seen after successful DB commit. Sync metrics
#   are stored in ImapSyncState and visible at /admin/imap_sync_states (HTML/JSON).
#
# Required environment
# - IMAP_USERNAME: Gmail username (email)
# - IMAP_PASSWORD: Gmail App Password (with 2FA enabled)
# - IMAP_MAILBOX_LABEL: dedicated Gmail label for list mail (configure a Gmail filter)
#
# Optional environment
# - IMAP_HOST (default: imap.gmail.com)
# - IMAP_PORT (default: 993)
# - IMAP_SSL  (default: true)

# Run (examples)
# - Script:      IMAP_USERNAME=... IMAP_PASSWORD=... IMAP_MAILBOX_LABEL=... ruby script/imap_idle.rb
#
# Stop / shutdown
# - Send SIGTERM or SIGINT (Ctrl+C). The runner exits the IDLE loop and disconnects cleanly.
#
# Notes
# - Use a dedicated Gmail account subscribed to the mailing list.
# - Prefer App Passwords over main credentials; rotate periodically.
# - One process per mailbox label/account.

require_relative "../config/environment"
require_relative "../app/services/imap_idle_runner"

logger = defined?(Rails) ? Rails.logger : Logger.new($stdout)
label = ENV['IMAP_MAILBOX_LABEL']
if label.nil? || label.strip.empty?
  STDERR.puts 'ERROR: IMAP_MAILBOX_LABEL must be set to a dedicated Gmail label (not INBOX). Configure a Gmail filter to label list mail.'
  exit 1
end

runner = ImapIdleRunner.new(label: label, logger: logger)

Signal.trap('TERM') do
  logger.info('[imap_idle] SIGTERM received, stopping...') if logger
  runner.stop!
end
Signal.trap('INT') do
  logger.info('[imap_idle] SIGINT received, stopping...') if logger
  runner.stop!
end

logger.info("[imap_idle] Starting IMAP IDLE runner for #{label}") if logger

begin
  # Infinite loop: use stop! via signal to exit
  runner.run
rescue SystemExit, Interrupt
  # normal exit
rescue => e
  logger.error("[imap_idle] Fatal error: #{e.class}: #{e.message}") if logger
  raise
ensure
  logger.info('[imap_idle] Exiting') if logger
end
