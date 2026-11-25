# frozen_string_literal: true

module Settings
  class MailboxesController < Settings::BaseController
    before_action :require_mailbox
    before_action :require_enabled, only: [ :update, :generate ]

    def show
    end

    def update
      if params[:password].to_s != params[:password_confirmation].to_s
        return redirect_to settings_mailbox_path, alert: "Passwords do not match"
      end

      if @mailbox.change_password(params[:password].to_s)
        redirect_to settings_mailbox_path, notice: "Mail password updated."
      else
        redirect_to settings_mailbox_path, alert: @mailbox.errors.full_messages.to_sentence
      end
    end

    def generate
      @generated_password = @mailbox.generate_password!
      # the password is on this page only, keep it out of caches
      response.headers["Cache-Control"] = "no-store"
      render :show
    end

    private

    def require_mailbox
      @mailbox = current_user.mailbox
      redirect_to settings_root_path, alert: "You do not have a mailbox" unless @mailbox
    end

    def require_enabled
      redirect_to settings_mailbox_path, alert: "This mailbox is disabled." if @mailbox.disabled?
    end

    def active_settings_section
      :mailbox
    end
  end
end
