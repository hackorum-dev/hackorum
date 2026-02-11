# frozen_string_literal: true

class Admin::ImapSyncStatesController < Admin::BaseController
  def active_admin_section
    :imap_sync
  end

  def index
    @states = ImapSyncState.order(:mailbox_label)
    respond_to do |format|
      format.html
      format.json do
        render json: @states.as_json(only: [
          :mailbox_label, :last_uid, :last_checked_at, :last_cycle_started_at,
          :last_cycle_duration_ms, :last_fetched_count, :last_ingested_count,
          :last_duplicate_count, :last_attachment_count, :last_patch_files_count,
          :last_backlog_count, :consecutive_error_count, :last_error_class,
          :last_error, :backoff_seconds, :created_at, :updated_at
        ])
      end
    end
  end
end
