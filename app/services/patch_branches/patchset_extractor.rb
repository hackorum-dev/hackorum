require "zlib"
require "stringio"
require "open3"

module PatchBranches
  class PatchsetExtractor
    Error = Class.new(StandardError)

    DEGENERATE_BASENAMES = [ "", ".", ".." ].freeze

    WRAPPER_SUFFIX = /\.(?:gz|bz2|txt)\z/i
    # Zero-padded like git format-patch output, so years (2024-...) don't count.
    SERIES_NUMBER = /(0\d{3,}|\d{5,})-.*\.(?:patch|diff)\z/i
    # git format-patch -v puts the marker at the start; mid-name v<n> tokens
    # are usually subject slugs, not versions.
    SERIES_VERSION = /\Av(\d+)(?=[-._])/i
    LOOSE_VERSION = /(?:\A|[-._])v(\d+)(?=[-._]|\z)/i

    PYTHON_BZ2_DECOMPRESS =
      "import sys,bz2; sys.stdout.buffer.write(bz2.decompress(sys.stdin.buffer.read()))"

    def initialize(message)
      @message = message
    end

    # Writes the message's patch attachments into dir, returns sorted paths.
    def extract(dir)
      # sort_by id, not the association's default: it has none, so postgres is
      # free to hand back colliding filenames in either order, and the collision
      # renaming below would then pick a different winner between runs
      patches = @message.attachments.sort_by(&:id).select(&:patch_submission_candidate?)
      raise Error, "no patch attachments on message #{@message.id}" if patches.empty?

      patches = select_series(patches)

      paths = patches.map do |attachment|
        if attachment.decoded_body.blank?
          raise Error, "empty attachment body for attachment #{attachment.id} (#{attachment.file_name})"
        end

        name, content = unwrap(attachment.file_name.to_s, attachment.decoded_body.to_s)
        basename = File.basename(name)
        basename = "attachment-#{attachment.id}.patch" if DEGENERATE_BASENAMES.include?(basename)
        path = unique_path(dir, basename)
        File.binwrite(path, content)
        path
      end

      sort_patch_files(paths)
    end

    private

    # When one message carries several versions of the same series (duplicate
    # series numbers), keep only the highest-version group.
    def select_series(patches)
      numbered = patches.select { |a| series_number(a.file_name.to_s) }
      return patches unless duplicate_series?(numbered)

      groups = numbered.group_by { |a| series_version(a.file_name.to_s) }
      versions = groups.keys.compact
      if versions.empty?
        raise_ambiguous("duplicate series numbers with no version markers", numbered)
      end

      chosen_version = versions.max
      chosen = groups[chosen_version]
      if duplicate_series?(chosen)
        raise_ambiguous("duplicate series numbers within version group v#{chosen_version}", chosen)
      end

      covered = chosen.map { |a| series_number(a.file_name.to_s) }
      missing = (numbered - chosen).map { |a| series_number(a.file_name.to_s) }.uniq - covered
      if missing.any?
        raise_ambiguous("version group v#{chosen_version} does not cover series #{missing.join(', ')}", numbered)
      end

      loose = (patches - numbered).reject do |a|
        version = loose_version(a.file_name.to_s)
        version && version != chosen_version
      end

      chosen + loose
    end

    def duplicate_series?(attachments)
      numbers = attachments.map { |a| series_number(a.file_name.to_s) }
      numbers.uniq.size < numbers.size
    end

    def series_number(name)
      base = File.basename(name)
      base = base.sub(WRAPPER_SUFFIX, "") while base.match?(WRAPPER_SUFFIX)
      base[SERIES_NUMBER, 1]&.to_i
    end

    def series_version(name)
      File.basename(name)[SERIES_VERSION, 1]&.to_i
    end

    def loose_version(name)
      File.basename(name)[LOOSE_VERSION, 1]&.to_i
    end

    def raise_ambiguous(reason, attachments)
      names = attachments.map(&:file_name).join(", ")
      raise Error, "ambiguous patchset: #{reason} (#{names})"
    end

    def unwrap(name, content)
      loop do
        case name
        when /\.gz\z/i
          content = Zlib::GzipReader.new(StringIO.new(content)).read
          name = name.sub(/\.gz\z/i, "")
        when /\.bz2\z/i
          content = bunzip2(content)
          name = name.sub(/\.bz2\z/i, "")
        when /\.txt\z/i
          name = name.sub(/\.txt\z/i, "")
        else
          return [ name, content ]
        end
      end
    rescue Zlib::Error => e
      raise Error, "decompression failed for #{name}: #{e.message}"
    end

    def bunzip2(content)
      out, status = Open3.capture2("bzip2", "-dc", stdin_data: content, binmode: true)
      raise Error, "bzip2 -dc failed" unless status.success?
      out
    rescue Errno::ENOENT
      bunzip2_python(content)
    rescue SystemCallError => e
      raise Error, "bzip2 spawn failed: #{e.message}"
    end

    def bunzip2_python(content)
      out, status = Open3.capture2("python3", "-c", PYTHON_BZ2_DECOMPRESS,
                                    stdin_data: content, binmode: true)
      raise Error, "python3 bz2 fallback failed" unless status.success?
      out
    rescue Errno::ENOENT
      raise Error, "no bzip2 decompressor available (bzip2 and python3 both missing)"
    rescue SystemCallError => e
      raise Error, "python3 spawn failed: #{e.message}"
    end

    def unique_path(dir, basename)
      path = File.join(dir, basename)
      return path unless File.exist?(path)

      n = 1
      n += 1 while File.exist?(path = File.join(dir, "#{n}-#{basename}"))
      path
    end

    # 4+ digit series number first, then the rest.
    def sort_patch_files(files)
      files.sort_by do |f|
        basename = File.basename(f)
        if basename =~ /(\d{4,})-.*\.(patch|diff)\z/i
          [ $1.to_i, basename ]
        else
          [ Float::INFINITY, basename ]
        end
      end
    end
  end
end
