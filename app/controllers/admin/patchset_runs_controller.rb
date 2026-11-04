# frozen_string_literal: true

class Admin::PatchsetRunsController < Admin::BaseController
  PER_PAGE = 50
  SORTS = { "duration" => "duration_s DESC NULLS LAST, id DESC", "tokens" => "input_tokens DESC NULLS LAST, id DESC" }.freeze
  REQUEUEABLE = %w[failed timeout].freeze

  def active_admin_section
    :patchset_runs
  end

  def index
    @sort = SORTS.key?(params[:sort]) ? params[:sort] : nil
    order = @sort ? Arel.sql(SORTS[@sort]) : { created_at: :desc }
    @runs = PatchsetRun.includes(:topic).order(order).page(params[:page]).per(PER_PAGE)
    @verdict_counts = CommitVerdict.where(patchset_run_id: @runs.map(&:id)).group(:patchset_run_id, :verdict).count.group_by { |(id, _), _| id }
    @status_counts = PatchsetRun.group(:status).count
    @queue_counts = Lineage::Queue.counts
  end

  def show
    @run = PatchsetRun.includes(:topic).find(params[:id])
    @lineages = @run.lineages.includes(:message).sort_by { |l| l.message.created_at }
    @verdicts = @run.verdicts.includes(:commit, author_message: :sender)
  end

  def requeue
    run = PatchsetRun.find(params[:id])
    unless REQUEUEABLE.include?(run.status)
      return redirect_to admin_patchset_run_path(run), alert: "Only failed or timed out runs can be requeued"
    end

    run.destroy!
    redirect_to admin_patchset_runs_path, notice: "Run #{run.id} removed, topic re-queued"
  end
end
