require "net/http"
require "json"

module PatchCi
  class GithubClient
    Error = Class.new(StandardError)

    PER_PAGE = 100
    # unfiltered runs() is a newest-N window, not full history - see method doc
    MAX_PAGES = 5
    IN_FLIGHT = %w[queued in_progress requested waiting pending].freeze

    Run = Struct.new(:id, :attempt, :branch, :status, :conclusion, :head_sha,
                     :queued_at, :started_at, :completed_at, keyword_init: true) do
      def in_flight?
        IN_FLIGHT.include?(status)
      end

      def completed?
        status == "completed"
      end
    end

    def initialize(repo:, token: ENV["HACKORUM_GITHUB_TOKEN"])
      raise Error, "HACKORUM_GITHUB_TOKEN is not set" if token.to_s.empty?
      @repo = repo
      @token = token
    end

    # Returns the newest runs, page by page, stopping at MAX_PAGES. Runs come
    # back newest-first and the history grows without bound, so this is a
    # deliberate newest-N window, NOT the full run history. Fine for ingestion,
    # which polls often enough that the newest page covers what changed.
    # Do NOT use this for counting in-flight jobs - use in_flight_count.
    def runs(status: nil, pages: MAX_PAGES)
      all = []
      (1..pages).each do |page|
        batch, raw_size = fetch_page(page, status: status)
        all.concat(batch)
        break if raw_size < PER_PAGE
      end
      all
    end

    # Queries github directly for each in-flight status instead of paging
    # through history and filtering client-side. These result sets are
    # bounded by how many jobs can run at once, so they never truncate.
    def in_flight_count(now: Time.current)
      cutoff = now - Config::GHOST_RUN_HOURS.hours
      IN_FLIGHT.sum { |state| runs(status: state).count { |run| !ghost?(run, cutoff) } }
    end

    private

    def ghost?(run, cutoff)
      run.queued_at.present? && Time.zone.parse(run.queued_at) < cutoff
    end

    def fetch_page(page, status: nil)
      uri = URI("https://api.github.com/repos/#{@repo}/actions/runs")
      params = { per_page: PER_PAGE, page: page }
      params[:status] = status if status
      uri.query = URI.encode_www_form(params)

      response = get(uri)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "GET #{uri} -> #{response.code}: #{response.body.to_s.slice(0, 300)}"
      end

      body = JSON.parse(response.body)
      runs = body["workflow_runs"]
      # a 200 with an unusable body is not evidence of zero runs; the caller
      # sizes its push budget on this and must not read it as "nothing running"
      raise Error, "GET #{uri} -> 200 but no workflow_runs array" unless runs.is_a?(Array)

      # slug sync branch is not a patch branch: no budget slot, no ingest
      kept = runs.reject { |raw| raw["head_branch"] == Config::SLUG_SYNC_BRANCH }
      [ kept.map { |raw| to_run(raw) }, runs.size ]
    rescue JSON::ParserError => e
      raise Error, "unparseable response: #{e.message}"
    end

    def get(uri)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.request(request)
      end
    end

    def to_run(raw)
      Run.new(
        id: raw["id"],
        attempt: raw["run_attempt"] || 1,
        branch: raw["head_branch"],
        status: raw["status"],
        conclusion: raw["conclusion"],
        head_sha: raw["head_sha"],
        queued_at: raw["created_at"],
        started_at: raw["run_started_at"],
        completed_at: (raw["updated_at"] if raw["status"] == "completed")
      )
    end
  end
end
