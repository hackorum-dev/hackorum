# Nothing under /api may send a draft, start a send, or queue or run a job.
# Included in every spec under spec/requests/api/v1.
module ApiNoSend
  JOB_EVENTS = %w[enqueue.active_job enqueue_at.active_job perform_start.active_job].freeze

  # marks the time a request is being answered: jobs of the setup of an example are not the API's
  module WatchedSession
    attr_accessor :job_watch

    def process(...)
      job_watch[:requests] += 1
      job_watch[:active] = true
      super
    ensure
      job_watch[:active] = false
    end
  end

  # marks the example groups the context is in
  module Watched; end
end

RSpec.shared_context "API never sends" do
  include ApiNoSend::Watched

  before do
    expect(SendOutgoingMessageJob).not_to receive(:perform_now)
    expect(SendOutgoingMessageJob).not_to receive(:perform_later)
    expect(SendOutgoingMessageJob).not_to receive(:new)
    expect(Gmail::SendClient).not_to receive(:send_raw)
    expect(OAuth::TokenRefresher).not_to receive(:call)
  end

  before do
    watch = api_job_watch
    next if watch[:subscriptions].any?

    record = ->(event) { watch[:jobs] << [ event.name, event.payload[:job].class.name ] if watch[:active] }
    watch[:subscriptions] = ApiNoSend::JOB_EVENTS.map { |name| ActiveSupport::Notifications.subscribe(name, &record) }
  end

  after do
    api_job_watch[:subscriptions].each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
    expect(api_job_watch[:jobs]).to eq([]), "requests queued or ran jobs: #{api_job_watch[:jobs].inspect}"
  end

  def api_job_watch
    @api_job_watch ||= { active: false, requests: 0, jobs: [], subscriptions: [] }
  end

  def create_session(app)
    super.tap do |session|
      session.extend(ApiNoSend::WatchedSession)
      session.job_watch = api_job_watch
    end
  end
end

RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{/spec/requests/api/v1/}) do |metadata|
    metadata[:api_no_send] = true
  end

  config.include_context "API never sends", api_no_send: true
end
