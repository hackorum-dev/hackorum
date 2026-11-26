module ClassifyApi
  class ClaimsController < BaseController
    RESULT_FIELDS = (::Classify::Claims::RESULT_FIELDS + %i[error_message stderr_tail duration_s]).freeze

    def create
      phases = Array(params[:phases]).presence || ::Classify::Queue::PHASES
      unknown = phases - ::Classify::Queue::PHASES
      return render json: { error: "unknown phases #{unknown.join(', ')}" }, status: :unprocessable_content if unknown.any?

      run = ::Classify::Claims.claim(worker: params.require(:worker), phases: phases)
      return head :no_content unless run
      render json: { run_id: run.id, topic_id: run.topic_id, mode: run.phase, prompt_version: run.prompt_version },
             status: :created
    end

    def bundle
      path = ::Classify::Claims.bundle_tar(run)
      send_file path, type: "application/gzip", filename: "#{run.id}.tar.gz"
    end

    def result
      fields = RESULT_FIELDS.to_h { |k| [ k, params[k] ] }.compact
      fields[:timed_out] = ActiveModel::Type::Boolean.new.cast(params[:timed_out]) || false
      result_path = params[:result].respond_to?(:path) ? params[:result].path : nil
      ::Classify::Claims.result!(run, fields, result_path: result_path)
      render json: { status: run.status, error: run.error, failure_kind: run.failure_kind }
    end

    def destroy
      ::Classify::Claims.release!(run)
      head :no_content
    end

    private

    def run = @run ||= ClassificationRun.find(params[:id])
  end
end
