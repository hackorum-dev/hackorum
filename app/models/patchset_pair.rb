class PatchsetPair < ApplicationRecord
  belongs_to :topic
  belongs_to :later_message, class_name: "Message"
  belongs_to :earlier_message, class_name: "Message"
end
