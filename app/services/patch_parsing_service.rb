require_relative "../../lib/patch_parser"

class PatchParsingService
  def initialize(attachment)
    @attachment = attachment
  end

  def parse!
    return unless @attachment.patch?
    return if @attachment.patch_files.exists? # Already parsed

    patch_content = @attachment.decoded_body
    return unless patch_content.present?

    parser = PatchParser.new(
      patch_content,
      filename: @attachment.file_name
    ) do |file_info|
      save_file_to_database(file_info)
    end

    parser.parse!
  end

  def extract_contrib_modules
    @attachment.patch_files.contrib_files.pluck(:filename).map do |filename|
      filename.split("/")[1] # contrib/module_name/file.c -> module_name
    end.uniq.compact
  end

  def extract_backend_areas
    @attachment.patch_files.backend_files.pluck(:filename).map do |filename|
      path_parts = filename.split("/")
      # src/backend/area/subarea/file.c -> area/subarea
      path_parts[2..-2]&.join("/") if path_parts.length > 3
    end.uniq.compact
  end

  private

  def save_file_to_database(file_info)
    @attachment.patch_files.create!(
      filename: file_info[:filename],
      old_filename: file_info[:old_filename],
      status: file_info[:status],
      line_changes: file_info[:line_changes]
    )
  rescue ActiveRecord::RecordNotUnique
    # File already exists, skip
  end
end
