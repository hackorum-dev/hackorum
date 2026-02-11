# frozen_string_literal: true

require "optparse"

module ImportOptions
  def self.parse!(argv = ARGV)
    options = { update_existing: [] }

    OptionParser.new do |opts|
      opts.banner = "Usage: #{$PROGRAM_NAME} [options] /path/to/mbox [...]"

      opts.on("--update-body", "Update body of existing messages") do
        options[:update_existing] |= [ :body ]
      end
      opts.on("--update-date", "Update date of existing messages") do
        options[:update_existing] |= [ :date ]
      end
      opts.on("--update-reply-to-message-id", "Update reply_to_message_id of existing messages") do
        options[:update_existing] |= [ :reply_to_message_id ]
      end
    end.parse!(argv)

    options
  end
end
