# frozen_string_literal: true

class Admin::ClassificationRunsController < Admin::BaseController
  PER_PAGE = 50
  SORTS = { "duration" => "duration_s DESC NULLS LAST, id DESC", "tokens" => "input_tokens DESC NULLS LAST, id DESC" }.freeze
  REQUEUEABLE = %w[failed timeout].freeze

  def active_admin_section
    :classification_runs
  end

  def index
    @sort = SORTS.key?(params[:sort]) ? params[:sort] : nil
    @status = ClassificationRun::STATUSES.include?(params[:status]) ? params[:status] : nil
    @phase = ClassificationRun::PHASES.include?(params[:phase]) ? params[:phase] : nil
    @kind = Classify::KIND_TAGS.include?(params[:kind]) ? params[:kind] : nil

    runs = ClassificationRun.includes(:topic, :feature_group)
    runs = runs.where(status: @status) if @status
    runs = runs.where(phase: @phase) if @phase
    runs = runs.where(kind: @kind) if @kind
    @runs = runs.order(@sort ? Arel.sql(SORTS[@sort]) : { created_at: :desc }).page(params[:page]).per(PER_PAGE)

    @status_counts = ClassificationRun.group(:status).count
    @kind_counts = ClassificationRun.done.group(:kind).count
    @queue_counts = Classify::Queue.counts
    @totals = ClassificationRun.pick(Arel.sql("sum(input_tokens), sum(cached_input_tokens), sum(output_tokens), avg(duration_s)"))
  end

  def show
    @run = ClassificationRun.includes(:topic, :feature_group).find(params[:id])
    result = @run.result || {}
    @linked = Topic.where(id: Array(result["join_linked"])).index_by(&:id)
  end

  def requeue
    run = ClassificationRun.find(params[:id])
    unless REQUEUEABLE.include?(run.status)
      return redirect_to admin_classification_run_path(run), alert: "Only failed or timed out runs can be requeued"
    end

    run.destroy!
    redirect_to admin_classification_runs_path, notice: "Run #{run.id} removed, thread re-queued"
  end
end
