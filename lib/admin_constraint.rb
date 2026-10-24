# frozen_string_literal: true

class AdminConstraint
  def matches?(request)
    User.from_session(request.session)&.admin? || false
  end
end
