module LineageApi
  class ClaimsController < BaseController
    RESULT_FIELDS = (::Lineage::Claims::RESULT_FIELDS + %i[error_message stderr_tail duration_s]).freeze

    def create
      phases = Array(params[:phases]).presence || ::Lineage::Queue::PHASES
      unknown = phases - ::Lineage::Queue::PHASES
      return render json: { error: "unknown phases #{unknown.join(', ')}" }, status: :unprocessable_content if unknown.any?

      run = ::Lineage::Claims.claim(worker: params.require(:worker), phases: phases)
      return head :no_content unless run
      render json: { run_id: run.id, topic_id: run.topic_id, mode: run.mode, prompt_version: run.prompt_version },
             status: :created
    end

    def bundle
      path = ::Lineage::Claims.bundle_tar(run)
      if path
        send_file path, type: "application/gzip", filename: "#{run.id}.tar.gz"
      else
        head :accepted
      end
    end

    def result
      fields = RESULT_FIELDS.to_h { |k| [ k, params[k] ] }.compact
      fields[:timed_out] = ActiveModel::Type::Boolean.new.cast(params[:timed_out]) || false
      result_path = params[:result].respond_to?(:path) ? params[:result].path : nil
      ::Lineage::Claims.result!(run, fields, result_path: result_path)
      render json: { status: run.status, error: run.error }
    end

    def destroy
      ::Lineage::Claims.release!(run)
      head :no_content
    end

    private

    def run = @run ||= PatchsetRun.find(params[:id])
  end
end
