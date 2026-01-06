class Attachment < ApplicationRecord
  belongs_to :message
  has_many :patch_files, dependent: :destroy
  
  def patch?
    file_name&.ends_with?('.patch') || file_name&.ends_with?('.diff') || patch_content?
  end
  
  def decoded_body
    Base64.decode64(body) if body.present?
  end

  def decoded_body_utf8
    raw = decoded_body
    return unless raw

    utf8 = raw.dup
    utf8.force_encoding("UTF-8")
    return utf8 if utf8.valid_encoding?

    raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\uFFFD")
  end
  
  private
  
  def patch_content?
    decoded_body&.starts_with?('diff ') || 
    decoded_body&.starts_with?('--- ') ||
    decoded_body&.starts_with?('*** ') ||
    decoded_body&.starts_with?('Index:') ||
    decoded_body&.include?('@@') ||
    decoded_body&.include?('***************')
  end
end
