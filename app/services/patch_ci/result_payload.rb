module PatchCi
  # result.json is written by a job that ran patch code, so everything here
  # treats it as hostile input: size cap first, then schema, then coercion.
  class ResultPayload
    # a realistic full executed list is ~116KB, the producer's tested worst
    # case ~159KB (collect_results.py caps names at 64 chars and asserts the
    # fit); 256KB keeps headroom on top of that bound
    MAX_BYTES = 256 * 1024
    MAX_FAILED = 200
    MAX_EXECUTED = 2000
    MAX_NAME = 200
    SCHEMA = 1
    INT4_MAX = 2_147_483_647
    INT8_MAX = 9_223_372_036_854_775_807

    attr_reader :error, :raw

    def self.parse(text)
      new(text)
    end

    def initialize(text)
      @error = nil
      @data = {}
      @raw = nil
      validate(text)
    end

    def valid?
      @error.nil?
    end

    def status = @data["status"]
    def run_id = int(@data["run_id"], max: INT8_MAX)
    def run_attempt = int(@data["run_attempt"], default: 1)
    def head_sha = string(@data["head_sha"])
    def pg_major = int(@data["pg_major"])
    def build_seconds = int(section("build")["seconds"])
    def test_seconds = int(section("tests")["seconds"])
    # both end up in a copy-paste docker command: nothing a shell would read
    IMAGE_REF = %r{\Aghcr\.io/[a-z0-9][a-z0-9._/-]{0,200}:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z}
    IMAGE_DIGEST = /\Asha256:[0-9a-f]{64}\z/

    def image_ref = string(section("image")["ref"]).then { |ref| ref.match?(IMAGE_REF) ? ref : "" }
    def image_digest = string(section("image")["digest"]).then { |d| d.match?(IMAGE_DIGEST) ? d : "" }
    def ccache_hit = int(section("ccache")["hit"])
    def ccache_miss = int(section("ccache")["miss"])

    def failed_tests
      list = section("tests")["failed"]
      return [] unless list.is_a?(Array)
      list.first(MAX_FAILED).map { |name| string(name).slice(0, MAX_NAME) }.reject(&:empty?)
    end

    def executed_tests
      list = executed_list
      return [] unless list
      list.first(MAX_EXECUTED).map { |name| string(name).slice(0, MAX_NAME) }.reject(&:empty?)
    end

    # nil (not 0) when the payload predates the executed list
    def tests_total
      executed_list ? executed_tests.size : nil
    end

    private

    def executed_list
      list = section("tests")["executed"]
      list.is_a?(Array) ? list : nil
    end

    def validate(text)
      text = text.to_s
      return fail!("payload too large") if text.bytesize > MAX_BYTES

      # postgres jsonb/text cannot store NUL bytes; a patch-controlled test
      # name carrying one would otherwise sail through validation and only
      # blow up later as a StatementInvalid on save. strip both the raw byte
      # and its JSON-escaped form before parsing.
      text = text.delete("\0").gsub(/\\u0000/i, "")

      begin
        parsed = JSON.parse(text)
      rescue JSON::ParserError => e
        return fail!("malformed json: #{e.message.slice(0, 200)}")
      end
      return fail!("payload is not an object") unless parsed.is_a?(Hash)

      @data = parsed
      return fail!("unsupported schema: #{parsed['schema'].inspect}") unless parsed["schema"] == SCHEMA
      return fail!("unknown status: #{parsed['status'].inspect}") unless PatchCiRun::STATUSES.include?(parsed["status"])

      @raw = parsed
      nil
    end

    def fail!(message)
      @error = message
      nil
    end

    def section(key)
      value = @data[key]
      value.is_a?(Hash) ? value : {}
    end

    def int(value, default: 0, max: INT4_MAX)
      # FloatDomainError covers Infinity/NaN, which JSON reaches via 1e400
      number = Integer(value)
      number.abs > max ? default : number
    rescue TypeError, ArgumentError, FloatDomainError
      default
    end

    def string(value)
      value.is_a?(String) ? value.scrub : ""
    end
  end
end
