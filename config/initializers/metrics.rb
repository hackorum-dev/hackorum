require "fileutils"

module Hackorum
  module Metrics
    def self.enabled? = ENV["METRICS_ENABLED"].to_s == "1"
  end
end

if Hackorum::Metrics.enabled?
  require "prometheus/client"
  require "prometheus/client/data_stores/direct_file_store"
  require "yabeda/rails"
  require "yabeda/prometheus"

  # multi-process puma: every worker writes its own file, the exporter sums them
  # (config/puma.rb wipes the dir on boot)
  store_dir = Rails.root.join("tmp", "prometheus")
  FileUtils.mkdir_p(store_dir)
  Prometheus::Client.config.data_store =
    Prometheus::Client::DataStores::DirectFileStore.new(dir: store_dir.to_s)

  # late require: the yabeda-rails railtie initializer does not run
  Yabeda::Rails.install!
  Rails.application.config.after_initialize do
    Yabeda.configure! unless Yabeda.already_configured?
  end

  Yabeda.configure do
    group :hackorum do
      gauge :solid_queue_ready_jobs,     comment: "Jobs waiting in ready executions", aggregation: :most_recent
      gauge :solid_queue_scheduled_jobs, comment: "Jobs scheduled for later", aggregation: :most_recent
      gauge :solid_queue_failed_jobs,    comment: "Jobs in failed executions", aggregation: :most_recent
      gauge :solid_queue_oldest_ready_seconds, comment: "Age of the oldest ready job", aggregation: :most_recent
    end

    collect do
      if SolidQueue::Job.table_exists?
        hackorum.solid_queue_ready_jobs.set({}, SolidQueue::ReadyExecution.count)
        hackorum.solid_queue_scheduled_jobs.set({}, SolidQueue::ScheduledExecution.count)
        hackorum.solid_queue_failed_jobs.set({}, SolidQueue::FailedExecution.count)
        oldest = SolidQueue::ReadyExecution.minimum(:created_at)
        hackorum.solid_queue_oldest_ready_seconds.set({}, oldest ? (Time.current - oldest).to_i : 0)
      else
        hackorum.solid_queue_ready_jobs.set({}, 0)
        hackorum.solid_queue_scheduled_jobs.set({}, 0)
        hackorum.solid_queue_failed_jobs.set({}, 0)
        hackorum.solid_queue_oldest_ready_seconds.set({}, 0)
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
      Rails.logger.warn("[metrics] solid queue collect failed: #{e.class}: #{e.message}")
    end
  end
end
