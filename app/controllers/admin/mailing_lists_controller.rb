# frozen_string_literal: true

class Admin::MailingListsController < Admin::BaseController
  before_action :set_mailing_list, only: [:edit, :update]

  def active_admin_section
    :mailing_lists
  end

  def index
    @mailing_lists = MailingList
      .select(
        "mailing_lists.*",
        "(SELECT COUNT(*) FROM message_mailing_lists WHERE message_mailing_lists.mailing_list_id = mailing_lists.id) AS messages_count",
        "(SELECT COUNT(*) FROM topic_mailing_lists WHERE topic_mailing_lists.mailing_list_id = mailing_lists.id) AS topics_count"
      )
      .order(:display_name)

    @topic_list_distribution = TopicMailingList.connection.select_rows(<<~SQL).to_h { |c, t| [c.to_i, t.to_i] }
      SELECT lists_count, COUNT(*) AS topic_count
      FROM (SELECT COUNT(*) AS lists_count FROM topic_mailing_lists GROUP BY topic_id) counts
      GROUP BY lists_count ORDER BY lists_count
    SQL
  end

  def new
    @mailing_list = MailingList.new
  end

  def create
    @mailing_list = MailingList.new(mailing_list_params)
    if @mailing_list.save
      redirect_to admin_mailing_lists_path, notice: "Mailing list created"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @mailing_list.update(mailing_list_params)
      redirect_to admin_mailing_lists_path, notice: "Mailing list updated"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_mailing_list
    @mailing_list = MailingList.find(params[:id])
  end

  def mailing_list_params
    permitted = params.require(:mailing_list).permit(:identifier, :display_name, :email, :description, :alternate_emails)
    if permitted[:alternate_emails].is_a?(String)
      permitted[:alternate_emails] = permitted[:alternate_emails].split(/[\r\n,]+/).map(&:strip).reject(&:blank?)
    end
    permitted
  end
end
