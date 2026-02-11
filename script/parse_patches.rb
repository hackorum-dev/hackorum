#!/usr/bin/env ruby
require_relative "../config/environment"

puts "Finding patch attachments..."

patch_attachments = Attachment.joins(:message)
                              .where("file_name ILIKE '%.patch' OR file_name ILIKE '%.diff'")
                              .or(Attachment.where("content_type LIKE '%text%'"))
                              .where.not(body: nil)
                              .includes(:message)

total = patch_attachments.count
processed = 0
found_patches = 0

puts "Found #{total} potential patch attachments to process..."

patch_attachments.find_each(batch_size: 100) do |attachment|
  processed += 1

  begin
    # Skip empty/blank attachments
    content = attachment.decoded_body
    if content.blank?
      puts "  [#{processed}/#{total}] Skipped #{attachment.file_name} (empty file)"
      next
    end

    service = PatchParsingService.new(attachment)
    if attachment.patch?
      service.parse!
      patch_count = attachment.patch_files.count
      if patch_count > 0
        found_patches += 1
        puts "  [#{processed}/#{total}] Processed #{attachment.file_name} (#{patch_count} files) from message '#{attachment.message.subject}'"
      else
        puts "  [#{processed}/#{total}] #{attachment.file_name} - no files extracted (unsupported format?)"
      end
    else
      puts "  [#{processed}/#{total}] Skipped #{attachment.file_name} (not a patch)"
    end
  rescue => e
    puts "  [#{processed}/#{total}] ERROR processing #{attachment.file_name}: #{e.message}"
  end
end

puts "\nProcessing complete!"
puts "  Total attachments processed: #{processed}"
puts "  Patch files found: #{found_patches}"
puts "  Total file changes recorded: #{PatchFile.count}"
