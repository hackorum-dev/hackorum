# frozen_string_literal: true

class PersonMerge < ApplicationRecord
  belongs_to :performed_by, class_name: "User"

  # Not an association: the column carries no foreign key, so the target may
  # already be gone if it was itself merged away later.
  def target_person
    Person.find_by(id: target_person_id)
  end
end
