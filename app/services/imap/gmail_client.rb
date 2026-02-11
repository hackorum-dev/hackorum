# frozen_string_literal: true

require "net/imap"

module Imap
  # Thin wrapper around Net::IMAP for Gmail usage.
  # Provides connect/login/select, UID search/fetch, IDLE, and mark-seen helpers.
  class GmailClient
    DEFAULT_HOST = "imap.gmail.com"
    DEFAULT_PORT = 993

    attr_reader :host, :port, :ssl, :username, :password, :mailbox

    def initialize(host: ENV["IMAP_HOST"] || DEFAULT_HOST,
                   port: (ENV["IMAP_PORT"] || DEFAULT_PORT).to_i,
                   ssl:  ENV.key?("IMAP_SSL") ? truthy?(ENV["IMAP_SSL"]) : true,
                   username: ENV["IMAP_USERNAME"],
                   password: ENV["IMAP_PASSWORD"],
                   mailbox:  ENV["IMAP_MAILBOX_LABEL"])
      @host = host
      @port = port
      @ssl = ssl
      @username = username
      @password = password
      @mailbox = mailbox
      @imap = nil
      @selected = nil
      if @mailbox.nil? || @mailbox.to_s.strip.empty?
        raise ArgumentError, "IMAP_MAILBOX_LABEL is required and must not be INBOX; configure a dedicated Gmail label for list mail"
      end
    end

    def connect!
      disconnect!
      @imap = Net::IMAP.new(@host, port: @port, ssl: @ssl)
      @imap.login(@username, @password) if @username && @password
      select_mailbox(@mailbox)
      self
    end

    def disconnect!
      return unless @imap
      begin
        @imap.logout
      rescue StandardError
        # ignore
      ensure
        begin
          @imap.disconnect
        rescue StandardError
        end
      end
      @imap = nil
      @selected = nil
    end

    def connected?
      !@imap.nil?
    end

    def select_mailbox(box)
      ensure_imap!
      @imap.select(box)
      @selected = box
      box
    end

    def selected_mailbox
      @selected
    end

    # Return array of UIDs strictly greater than given uid (or all if uid <= 0)
    def uid_search_greater_than(uid)
      ensure_imap!
      criteria = if uid.to_i > 0
                   [ "UID", "#{uid.to_i + 1}:*" ]
      else
                   [ "ALL" ]
      end
      @imap.uid_search(criteria)
    end

    def uid_fetch_rfc822(uid)
      ensure_imap!
      data = @imap.uid_fetch(uid, "RFC822")
      return nil if data.nil? || data.empty?
      data.first.attr["RFC822"]
    end

  def mark_seen(uid)
    ensure_imap!
    @imap.uid_store(uid, "+FLAGS.SILENT", [ :Seen ])
    true
  end

  # Returns a sorted list of UIDs greater than the given UID, limited to a batch size.
  # Uses UID FETCH to avoid SEARCH parsing quirks and to keep requests bounded.
  def uids_after(uid, batch_size: (ENV["IMAP_BATCH_SIZE"] || 200).to_i)
    ensure_imap!
    start = uid.to_i + 1
    last = max_uid
    return [] if last.nil? || last < start
    finish = [ last, start + batch_size - 1 ].min
    data = @imap.uid_fetch("#{start}:#{finish}", [ "UID" ])
    (data || []).map { |d| d.attr["UID"] }.compact.sort
  end

  # Returns the highest UID in the selected mailbox/label, or 0 if empty
  def max_uid
    ensure_imap!
    data = @imap.uid_fetch("*", [ "UID" ])
    return 0 if data.nil? || data.empty?
    data.first.attr["UID"]
  end

    # Performs a single IDLE cycle up to timeout seconds.
    # Returns :activity if any notification arrived, :timeout if none.
    # If a block is given, yields each response as it arrives.
    def idle_once(timeout: 1500)
      ensure_imap!
      got_activity = false
      begin
        if @imap.respond_to?(:idle)
          # Break IDLE promptly on first response so the caller can FETCH.
          idle_done_called = false
          @imap.idle(timeout) do |resp|
            got_activity = true
            yield resp if block_given?
            unless idle_done_called
              idle_done_called = true
              Thread.new { @imap.idle_done }
            end
          end
        else
          # Fallback: manual IDLE
          @imap.send_command("IDLE")
          start_time = Time.now
          while (Time.now - start_time) < timeout
            resp = @imap.get_response
            if resp
              got_activity = true
              yield resp if block_given?
              @imap.idle_done
              break
            else
              sleep 0.5
            end
          end
          # If we timed out without activity, end IDLE cleanly
          @imap.idle_done unless got_activity
        end
      rescue Net::IMAP::Error, IOError => e
        raise e
      end
      got_activity ? :activity : :timeout
    end

    private

    def ensure_imap!
      raise "Not connected" unless @imap
    end

    def self.truthy?(v)
      %w[1 true yes on].include?(v.to_s.downcase)
    end
    def truthy?(v) = self.class.truthy?(v)
  end
end
