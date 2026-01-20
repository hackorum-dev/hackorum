# frozen_string_literal: true

class ImapIdleRunner
  DEFAULT_IDLE_TIMEOUT = 1500 # 25 minutes (Gmail drops ~29m, we re-IDLE earlier)

  def initialize(label: ENV['IMAP_MAILBOX_LABEL'],
                 client: nil,
                 ingestor: EmailIngestor.new,
                 logger: (defined?(Rails) ? Rails.logger : Logger.new($stdout)))
    @label = label
    @client = client || Imap::GmailClient.new(mailbox: label)
    @ingestor = ingestor
    @logger = logger
    @backoff = 1
    @stop = false
    if (@label.nil? || @label.to_s.strip.empty?)
      raise ArgumentError, "IMAP_MAILBOX_LABEL is required and must point to a dedicated Gmail label (not INBOX)"
    end
  end

  # Public: Run the runner with an advisory lock so only one instance is active.
  # Options:
  #   max_cycles: Integer or nil — number of idle cycles to run after initial catch-up (nil = infinite)
  #   idle_timeout: Integer seconds per idle cycle
  def run(max_cycles: nil, idle_timeout: DEFAULT_IDLE_TIMEOUT)
    lock_key = "imap_idle:#{@label}"
    AdvisoryLock.with_lock(lock_key) do
      begin
        main_loop(max_cycles: max_cycles, idle_timeout: idle_timeout)
      rescue => e
        @logger.error("IMAP runner fatal error: #{e.class}: #{e.message}")
        update_state(last_error: short_error(e))
        raise
      end
    end
  end

  private

  def main_loop(max_cycles:, idle_timeout:)
    cycles = 0
    connect!
    catch_up!
    loop do
      break if @stop
      break if max_cycles && cycles >= max_cycles
      cycles += 1

      begin
        cycle_started = Time.now
        update_state(last_cycle_started_at: cycle_started)

        res = instrument('imap.idle', label: @label, timeout: idle_timeout) do
          @client.idle_once(timeout: idle_timeout) { |_resp| }
        end
        log_info(event: 'idle', label: @label, result: res)

        metrics = incremental_sync!
        duration_ms = ((Time.now - cycle_started) * 1000).to_i
        update_state({
          last_cycle_duration_ms: duration_ms,
          last_fetched_count: metrics[:fetched_count],
          last_ingested_count: metrics[:ingested_count],
          last_duplicate_count: metrics[:duplicate_count],
          last_attachment_count: metrics[:attachments_count],
          last_patch_files_count: metrics[:patch_files_count],
          last_backlog_count: metrics[:backlog_count],
          consecutive_error_count: 0,
          backoff_seconds: 0
        })
        instrument('imap.incremental_sync', label: @label, **metrics.merge(duration_ms: duration_ms)) { nil }
        @backoff = 1
      rescue => e
        log_warn(event: 'error', where: 'idle_or_sync', error_class: e.class.to_s, message: e.message, backoff: @backoff)
        update_state(last_error: short_error(e), last_error_class: e.class.to_s, consecutive_error_count: state.consecutive_error_count.to_i + 1, backoff_seconds: @backoff)
        break if @stop
        reconnect_with_backoff
      ensure
        update_state(last_checked_at: Time.now)
      end
    end
  ensure
    disconnect!
  end

  def connect!
    @client.connect!
  end

  def disconnect!
    @client.disconnect!
  rescue StandardError
  end

  def reconnect_with_backoff
    sleep_seconds = [@backoff, 60].min
    sleep sleep_seconds
    @backoff = [@backoff * 2, 60].min
    connect!
  end

  def state
    @state ||= ImapSyncState.for_label(@label)
  end

  def update_state(attrs)
    state.update_columns(attrs) # avoid validations, just store diagnostics
  end

  def catch_up!
    loop do
      metrics = incremental_sync!
      break if metrics[:fetched_count].to_i == 0
    end
  end

  def incremental_sync!
    uids = instrument('imap.search', label: @label, last_uid: state.last_uid.to_i) do
      @client.uids_after(state.last_uid.to_i)
    end
    fetched = uids&.size || 0
    return { fetched_count: 0, ingested_count: 0, duplicate_count: 0, attachments_count: 0, patch_files_count: 0, backlog_count: 0 } if fetched == 0

    ingested = 0
    duplicates = 0
    attachments = 0
    patch_files = 0

    uids.sort.each do |uid|
      result = process_uid(uid)
      if result[:ingested]
        ingested += 1
        attachments += result[:attachments]
        patch_files += result[:patch_files]
      else
        duplicates += 1
      end
    end

    { fetched_count: fetched, ingested_count: ingested, duplicate_count: duplicates, attachments_count: attachments, patch_files_count: patch_files, backlog_count: fetched }
  end

  def process_uid(uid)
    raw = instrument('imap.fetch', label: @label, uid: uid) do
      @client.uid_fetch_rfc822(uid)
    end
    return unless raw

    msg = nil
    ActiveRecord::Base.transaction do
      msg = instrument('ingestor.ingest', uid: uid) do
        @ingestor.ingest_raw(raw, trust_date: true)
      end
    end

    # Only after commit and successful ingest do we mark seen and advance the cursor
    @client.mark_seen(uid)
    state.update!(last_uid: uid, last_checked_at: Time.now, last_error: nil)
    log_info(event: 'ingest', uid: uid, message_id: msg&.message_id, duplicate: (msg.nil?), attachments: (msg ? msg.attachments.count : 0), patch_files: (msg ? msg.attachments.joins(:patch_files).count : 0))
    { ingested: !msg.nil?, attachments: (msg ? msg.attachments.count : 0), patch_files: (msg ? msg.attachments.joins(:patch_files).count : 0) }
  rescue => e
    log_error(event: 'ingest_error', uid: uid, error_class: e.class.to_s, message: e.message)
    update_state(last_error: short_error(e), last_checked_at: Time.now)
    # Do not advance last_uid on failure; idempotency ensures safe retry
    { ingested: false, attachments: 0, patch_files: 0 }
  end

  def short_error(e)
    msg = e.message.to_s
    msg.length > 500 ? msg[0, 500] + '…' : msg
  end

  public

  def stop!
    @stop = true
    begin
      disconnect!
    rescue StandardError
    end
  end

  def respond_to_logger_info?
    @logger && @logger.respond_to?(:info)
  end
  def respond_to_logger_warn?
    @logger && @logger.respond_to?(:warn)
  end
  def respond_to_logger_error?
    @logger && @logger.respond_to?(:error)
  end

  def log_info(payload)
    @logger.info(payload) if respond_to_logger_info?
  end
  def log_warn(payload)
    @logger.warn(payload) if respond_to_logger_warn?
  end
  def log_error(payload)
    @logger.error(payload) if respond_to_logger_error?
  end

  def instrument(name, **payload)
    if defined?(ActiveSupport::Notifications)
      ActiveSupport::Notifications.instrument(name, payload) { yield }
    else
      yield
    end
  end
end
