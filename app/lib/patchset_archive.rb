require "zlib"
require "rubygems/package"

class PatchsetArchive
  def self.build(message:, attachment_number:, host: nil)
    patches = message.attachments
                     .select(&:patch_submission_candidate?)
                     .sort_by(&:file_name)
    return nil if patches.empty?

    topic = message.topic

    tar_gz = StringIO.new
    Zlib::GzipWriter.wrap(tar_gz) do |gz|
      Gem::Package::TarWriter.new(gz) do |tar|
        metadata = build_metadata(topic, message, attachment_number, host: host)
        tar.add_file_simple("hackorum.json", 0644, metadata.bytesize) do |io|
          io.write(metadata)
        end
        used = Set["hackorum.json"]
        patches.each_with_index do |patch, idx|
          content = patch.decoded_body
          tar.add_file_simple(entry_name(patch.file_name, idx, used), 0644, content.bytesize) do |io|
            io.write(content)
          end
        end
      end
    end

    {
      data: tar_gz.string,
      filename: "topic-#{topic.id}-msg#{attachment_number}-patchset.tar.gz"
    }
  end

  def self.build_metadata(topic, message, attachment_number, host: nil)
    first_message = topic.messages.order(:created_at).first
    first_message_id = first_message&.message_id

    effective_host = host ||
                     Rails.application.config.action_mailer.default_url_options&.dig(:host) ||
                     "localhost"

    {
      attachment_number: attachment_number,
      topic_id: topic.id,
      submission_date: message.created_at.iso8601,
      hackorum_url: Rails.application.routes.url_helpers.topic_url(topic, host: effective_host),
      upstream_url: first_message_id && "https://www.postgresql.org/message-id/flat/#{ERB::Util.url_encode(first_message_id)}"
    }.compact.to_json
  end

  # tar entry names come from mail: no paths, at most 100 bytes (ustar
  # without prefix), unique so extraction does not overwrite
  def self.entry_name(file_name, idx, used)
    name = File.basename(file_name.to_s.tr("\\", "/")).delete("\0")
    name = "patch-#{idx + 1}.patch" if [ "", ".", ".." ].include?(name)
    name = truncate_name(name)
    candidate = name
    n = 1
    while used.include?(candidate)
      candidate = truncate_name("#{n}-#{name}")
      n += 1
    end
    used << candidate
    candidate
  end

  def self.truncate_name(name)
    return name if name.bytesize <= 100
    ext = File.extname(name).byteslice(0, 20).to_s.scrub("")
    base = name.delete_suffix(File.extname(name))
    base.byteslice(0, 100 - ext.bytesize).scrub("") + ext
  end

  private_class_method :build_metadata, :entry_name, :truncate_name
end
