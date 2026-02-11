class Mention < ApplicationRecord
  belongs_to :message
  belongs_to :alias, class_name: "Alias"
  belongs_to :person

  def display_alias
    person&.default_alias || self.alias
  end
end
