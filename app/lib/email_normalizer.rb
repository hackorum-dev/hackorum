module EmailNormalizer
  module_function

  def normalize(email)
    email.to_s.strip.downcase.presence
  end
end
