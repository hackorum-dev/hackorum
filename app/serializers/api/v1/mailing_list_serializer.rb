module Api
  module V1
    class MailingListSerializer < BaseSerializer
      def brief
        {
          identifier: record.identifier,
          display_name: record.display_name,
          hidden_by_default: record.hidden_by_default
        }
      end
    end
  end
end
