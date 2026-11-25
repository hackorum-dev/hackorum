# frozen_string_literal: true

class Admin::MailboxAddressesController < Admin::BaseController
  before_action :set_mailbox

  def active_admin_section
    :mailboxes
  end

  def create
    address = @mailbox.add_alias(params[:local_part])
    if address.persisted?
      redirect_to edit_admin_mailbox_path(@mailbox), notice: "Alias added"
    else
      redirect_to edit_admin_mailbox_path(@mailbox), alert: address.errors.full_messages.to_sentence
    end
  end

  def destroy
    address = @mailbox.addresses.find(params[:id])
    if address.destroy
      redirect_to edit_admin_mailbox_path(@mailbox), notice: "Alias removed"
    else
      redirect_to edit_admin_mailbox_path(@mailbox), alert: "The login address cannot be removed"
    end
  end

  private

  def set_mailbox
    @mailbox = Mailbox.find(params[:mailbox_id])
  end
end
