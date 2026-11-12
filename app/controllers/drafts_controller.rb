class DraftsController < ApplicationController
  before_action :require_authentication
  before_action :set_draft, only: [ :show, :update, :destroy, :confirm, :send_now, :edit ]
  before_action :reject_sent_drafts, only: [ :update, :destroy, :edit, :confirm, :send_now ]
  layout :resolve_layout

  CHANGED_ELSEWHERE = "This draft was changed elsewhere. Reload the composer to see what would be sent."

  include DraftSidebarLoader

  helper_method :active_settings_section

  def index
    @state = (params[:state].presence_in(%w[all in_progress sent failed]) || "all")
    scope  = current_user.outgoing_drafts
    @drafts = case @state
    when "in_progress" then scope.where(status: %w[idle sending]).where(last_send_error: nil)
    when "sent"        then scope.sent
    when "failed"      then scope.idle.where.not(last_send_error: nil)
    else                    scope
    end
    @drafts = @drafts
                .includes(:topic, :reply_to_message, :sender_alias, :sent_message)
                .order(Arel.sql("COALESCE(sent_at, updated_at) DESC"))
                .page(params[:page].to_s[/\A\d{1,6}\z/] || 1).per(50)
  end

  def show
  end

  def create
    parent = Message.find(params[:reply_to_message_id])
    draft = Drafts::Creator.call(user: current_user, reply_to_message: parent, quote: params[:selected_text]).draft
    @draft = draft
    @sidebar_drafts, @message_numbers = load_sidebar_drafts(parent.topic)
    respond_to do |format|
      format.json { render json: { id: draft.id } }
      format.turbo_stream # renders create.turbo_stream.slim
      format.html { redirect_to topic_path(parent.topic, anchor: "message-#{parent.id}") }
    end
  rescue Drafts::Creator::NoSendIdentity
    head :forbidden
  rescue Drafts::Creator::NoSenderAlias
    head :unprocessable_entity
  end

  def edit
    render partial: "drafts/composer", locals: { draft: @draft }, layout: false
  end

  def update
    return head :conflict if @draft.sending?
    @draft.assign_attributes(draft_params)
    @draft.last_edited_via_token = nil if @draft.changed?
    @draft.save!
    response.headers["X-Draft-Version"] = @draft.version
    head :no_content
  end

  def destroy
    @reply_to_message_id = @draft.reply_to_message_id
    topic = @draft.topic
    @draft.destroy!
    @sidebar_drafts, @message_numbers = load_sidebar_drafts(topic)
    respond_to do |format|
      format.turbo_stream
      format.html { head :no_content }
    end
  end

  def confirm
    return render plain: CHANGED_ELSEWHERE, status: :conflict unless current_version?

    @recipients = Outgoing::RecipientResolver.for(@draft)
    render layout: false
  rescue Outgoing::RecipientResolver::MissingPostAddressError
    render plain: "This mailing list isn't configured for sending. An admin must set its post_address.",
           status: :unprocessable_entity
  rescue Outgoing::RecipientResolver::MissingDevOverrideError
    render plain: "Dev mode requires HACKORUM_DEV_REPLY_TO env var to be set.",
           status: :unprocessable_entity
  rescue Outgoing::RecipientResolver::RealListAddressInDevError
    render plain: "Refusing to send: HACKORUM_DEV_REPLY_TO matches a real list address. Change it to a personal mailbox.",
           status: :unprocessable_entity
  end

  def send_now
    conflict = nil
    @draft.with_lock do
      conflict = "Draft is already being sent." unless @draft.idle?
      conflict ||= CHANGED_ELSEWHERE unless current_version?
      next if conflict

      @draft.update!(
        status: OutgoingDraft::STATUS_SENDING,
        sending_started_at: Time.current,
        last_send_error: nil
      )
    end

    if conflict
      return render plain: conflict, status: :conflict
    end

    # Sync send: by the time the redirect runs, the draft is either destroyed
    # (success), reset to idle with last_send_error (permanent), or still in
    # sending status (transient — retry_on rescued and re-enqueued the job).
    # The composer partial renders a "Sending…" placeholder for that last case.
    SendOutgoingMessageJob.perform_now(@draft.id)
    redirect_to topic_path(@draft.topic, anchor: "message-#{@draft.reply_to_message_id}")
  end

  private

  def set_draft
    @draft = current_user.outgoing_drafts.find(params[:id])
  end

  def reject_sent_drafts
    if @draft&.sent?
      redirect_to draft_path(@draft),
                  status: :unprocessable_entity,
                  alert: "This message has already been sent."
    end
  end

  def current_version?
    params[:version].to_s == @draft.version
  end

  def draft_params
    params.require(:outgoing_draft).permit(:subject, :body)
  end

  def active_settings_section
    :my_emails
  end

  def resolve_layout
    %w[index show].include?(action_name) ? "settings" : "application"
  end
end
