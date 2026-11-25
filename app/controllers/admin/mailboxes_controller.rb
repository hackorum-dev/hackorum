# frozen_string_literal: true

class Admin::MailboxesController < Admin::BaseController
  before_action :set_mailbox, only: [ :edit, :update, :destroy, :confirm_destroy, :disable, :enable ]
  before_action :require_disabled, only: [ :destroy, :confirm_destroy ]

  def active_admin_section
    :mailboxes
  end

  def index
    @mailboxes = Mailbox.includes(:user, :addresses).order(:id)
  end

  def new
    @form = {}
    @errors = []
  end

  def create
    @form = params.require(:mailbox).permit(:username, :login, :quota_mb).to_h.symbolize_keys
    user = User.active.find_by("lower(username) = ?", @form[:username].to_s.strip.downcase)
    if user.nil?
      @errors = [ "User not found" ]
      return render :new, status: :unprocessable_content
    end

    mailbox = Mailbox.grant!(
      user: user,
      login: @form[:login].presence || user.username,
      quota_mb: @form[:quota_mb].presence || Mailbox::DEFAULT_QUOTA_MB
    )
    redirect_to edit_admin_mailbox_path(mailbox), notice: "Mailbox created"
  rescue ActiveRecord::RecordInvalid => e
    @errors = e.record.errors.full_messages
    render :new, status: :unprocessable_content
  end

  def edit
  end

  def update
    if @mailbox.update(params.require(:mailbox).permit(:quota_mb))
      redirect_to edit_admin_mailbox_path(@mailbox), notice: "Mailbox updated"
    else
      render :edit, status: :unprocessable_content
    end
  end

  def confirm_destroy
  end

  def destroy
    @mailbox.destroy!
    redirect_to admin_mailboxes_path, notice: "Mailbox deleted"
  end

  def disable
    @mailbox.disable!
    redirect_to admin_mailboxes_path, notice: "Mailbox disabled"
  end

  def enable
    if @mailbox.enable!
      redirect_to admin_mailboxes_path, notice: "Mailbox enabled"
    else
      redirect_to admin_mailboxes_path, alert: "User is deleted"
    end
  end

  private

  def set_mailbox
    @mailbox = Mailbox.find(params[:id])
  end

  def require_disabled
    redirect_to admin_mailboxes_path, alert: "Disable the mailbox first" unless @mailbox.disabled?
  end
end
