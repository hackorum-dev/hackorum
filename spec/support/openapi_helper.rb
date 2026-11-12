require "json_schemer"

# Validates API responses against docs/api/openapi.yaml.
module OpenapiHelper
  PREFIX = "/api/v1"
  SOURCE = Rails.root.join("docs/api/openapi.yaml")
  SPEC_DIR = Rails.root.join("spec/requests/api/v1")
  CATCH_ALL = "api/v1/errors"
  ERROR_SCHEMA = %w[components schemas Error].freeze
  UNKNOWN_PATH_STATUSES = (ApiExceptionsApp::CODES.keys + [ 413, 429 ]).freeze
  RESPONSE_KEY = /\A(\d{3}|default)\z/
  VERBS = %w[get put post delete options head patch trace].freeze
  JSON_MEDIA = %r{\Aapplication/(.+\+)?json\z}
  BODY_VERBS = %w[post put patch].freeze
  BODY_MEDIA = "application/json"

  class Contract
    SCHEMA_MAPS = %w[properties patternProperties $defs dependentSchemas].freeze
    SCHEMA_LISTS = %w[allOf anyOf oneOf prefixItems].freeze
    SCHEMA_SINGLES = %w[items additionalProperties unevaluatedProperties not if then else contains propertyNames].freeze
    VALUE_KEYS = %w[example examples default enum const].freeze
    NAME_MAPS = %w[paths responses headers content parameters requestBodies securitySchemes links callbacks pathItems].freeze

    attr_reader :document, :validated

    def initialize(document)
      @document = document
      @validated = Set.new
    end

    def schemer
      @schemer ||= JSONSchemer.openapi(document)
    end

    def operations
      (document["paths"] || {}).flat_map do |template, item|
        item.keys.select { |key| VERBS.include?(key) }.map { |verb| [ template, verb ] }
      end.to_set
    end

    def record(template, verb, status)
      validated << [ template, verb, status ]
    end

    def unexercised
      operations.reject do |template, verb|
        validated.any? { |t, v, status| t == template && v == verb && status.between?(200, 299) }
      end.sort
    end

    # message for a response that does not match the document, nil when it does
    def check(request, response)
      verb = request.method.downcase
      template = OpenapiHelper.template(*OpenapiHelper.matched_route(request))
      found =
        if template
          violations(template: template, verb: verb, status: response.status, media_type: response.media_type, body: response.body)
        else
          unknown_path_violations(status: response.status, media_type: response.media_type, body: response.body, head: verb == "head")
        end
      found = request_violations(template, verb, request.raw_post) if found.empty? && template && response.status.between?(200, 299)
      if found.empty?
        record(template, verb, response.status) if template
        return
      end

      label = template ? "#{verb.upcase} #{template}" : "unknown path"
      "#{request.method} #{request.path} -> #{response.status} (#{label}) does not match openapi.yaml:\n  #{found.join("\n  ")}"
    end

    def violations(template:, verb:, status:, media_type:, body:)
      item = document.dig("paths", template) || {}
      head = verb == "head" && !item.key?("head")
      verb = "get" if head
      responses = item.dig(verb, "responses")
      return [ "#{verb.upcase} #{template} is not in the document" ] unless responses

      key = status.to_s
      key = "default" if !responses.key?(key) && status.to_i >= 400
      return [ "#{verb.upcase} #{template}: status #{status} is not documented" ] unless responses.key?(key)

      tokens, documented, problem = resolve([ "paths", template, verb, "responses", key ])
      return [ problem ] if problem

      body_violations(tokens, documented, media_type, body, head: head)
    end

    # the documented schema of an operation's JSON body, nil without one
    def request_body_schema(template, verb)
      tokens = request_schema_tokens(template, verb)
      fetch(tokens) && resolve(tokens)[1]
    end

    # a request that was answered with success must match the documented body
    def request_violations(template, verb, raw)
      tokens = request_schema_tokens(template, verb)
      return [] unless fetch(tokens)

      json_violations(tokens, raw).map { |message| "request body: #{message}" }
    end

    def unknown_path_violations(status:, media_type:, body:, head: false)
      found = []
      unless UNKNOWN_PATH_STATUSES.include?(status)
        found << "unknown path: status #{status}, expected one of #{UNKNOWN_PATH_STATUSES.join(', ')}"
      end
      return found << "unknown path: the document has no #{pointer(ERROR_SCHEMA)}" unless fetch(ERROR_SCHEMA)
      return found << "unknown path: media type #{media_type.inspect}, expected application/json" unless JSON_MEDIA.match?(media_type.to_s)

      found.concat(json_violations(ERROR_SCHEMA, body).map { |message| "unknown path: #{message}" }) unless head
      found
    end

    def lint
      lint_response_keys + lint_schemas + lint_refs + lint_security + lint_request_bodies
    end

    # a body is documented where the verb takes one: required, JSON only, a closed object
    def lint_request_bodies
      operations.sort.flat_map do |template, verb|
        where = pointer([ "paths", template, verb, "requestBody" ])
        body = document.dig("paths", template, verb, "requestBody")
        takes = BODY_VERBS.include?(verb)
        next (takes ? [ "#{where}: a #{verb.upcase} operation must document its request body" ] : []) if body.nil?
        next [ "#{where}: a #{verb.upcase} operation takes no request body" ] unless takes

        found = []
        found << "#{where} must be required" unless body["required"] == true
        found << "#{where} must have #{BODY_MEDIA} as its only content" unless body["content"].is_a?(Hash) && body["content"].keys == [ BODY_MEDIA ]
        schema = request_body_schema(template, verb)
        closed = schema.is_a?(Hash) && schema["type"] == "object" && schema["additionalProperties"] == false && schema["properties"].is_a?(Hash)
        found << "#{where}: the schema must be an object with properties and additionalProperties false" unless closed
        found
      end
    end

    def lint_response_keys
      found = []
      each_node do |node, path|
        next unless path.last == "responses" && path != %w[components responses]

        node.each_key do |key|
          next if key.is_a?(String) && RESPONSE_KEY.match?(key)
          found << "#{pointer(path)}: response key #{key} (#{key.class}) must be a quoted status or default"
        end
      end
      found
    end

    def lint_schemas
      found = []
      each_node do |node, path, schema|
        next unless schema

        properties = node["properties"]
        if properties && !node.key?("additionalProperties") && !node.key?("unevaluatedProperties")
          found << "#{pointer(path)} has properties but no additionalProperties or unevaluatedProperties"
        end
        (Array(node["required"]) - (properties || {}).keys).each do |name|
          found << "#{pointer(path)} requires #{name}, which is not in properties"
        end
      end
      found
    end

    def lint_refs
      found = []
      each_node do |node, path|
        ref = node["$ref"]
        next unless ref

        found << "#{pointer(path)}: $ref #{ref} does not resolve" unless ref.is_a?(String) && ref.start_with?("#/") && fetch(tokens(ref))
      end
      found
    end

    def lint_security
      defined = (document.dig("components", "securitySchemes") || {}).keys
      requirements = { "#/security" => document["security"] }
      operations.each do |template, verb|
        requirements[pointer([ "paths", template, verb, "security" ])] = document.dig("paths", template, verb, "security")
      end
      requirements.flat_map do |where, list|
        (Array(list).flat_map(&:keys) - defined).map { |name| "#{where}: security scheme #{name} is not defined" }
      end
    end

    private

    def request_schema_tokens(template, verb)
      [ "paths", template, verb, "requestBody", "content", BODY_MEDIA, "schema" ]
    end

    def pointer(tokens)
      "#/" + tokens.map { |token| token.to_s.gsub("~", "~0").gsub("/", "~1") }.join("/")
    end

    def tokens(ref)
      ref.delete_prefix("#/").split("/").map { |token| token.gsub("~1", "/").gsub("~0", "~") }
    end

    def fetch(tokens)
      tokens.reduce(document) do |node, token|
        case node
        when Hash then node[token]
        when Array then token.match?(/\A\d+\z/) ? node[token.to_i] : nil
        end
      end
    end

    def resolve(tokens)
      seen = []
      loop do
        node = fetch(tokens)
        return [ tokens, nil, "#{pointer(seen.last)}: $ref #{pointer(tokens)} does not resolve" ] unless node.is_a?(Hash)
        return [ tokens, node, nil ] unless node.key?("$ref")
        return [ tokens, nil, "#{pointer(tokens)}: $ref loop" ] if seen.include?(tokens)

        seen << tokens
        ref = node["$ref"]
        return [ tokens, nil, "#{pointer(tokens)}: $ref #{ref} does not resolve" ] unless ref.is_a?(String) && ref.start_with?("#/")
        tokens = tokens(ref)
      end
    end

    def body_violations(tokens, documented, media_type, body, head:)
      content = documented["content"] || {}
      if content.empty?
        return [] if head || body.to_s.empty?
        return [ "#{pointer(tokens)} documents no content, but the body has #{body.bytesize} bytes" ]
      end
      unless content.key?(media_type)
        return [ "#{pointer(tokens)}: media type #{media_type.inspect} is not documented, expected one of #{content.keys.join(', ')}" ]
      end
      return [] unless JSON_MEDIA.match?(media_type)

      schema = tokens + [ "content", media_type, "schema" ]
      return [ "#{pointer(schema)}: a JSON response has no schema" ] if fetch(schema).nil?

      head ? [] : json_violations(schema, body)
    end

    def json_violations(schema, body)
      return [ "the body is empty, expected JSON" ] if body.to_s.empty?

      data = begin
        JSON.parse(body)
      rescue JSON::ParserError => e
        return [ "the body is not JSON: #{e.message.truncate(100)}" ]
      end
      fragment = pointer(schema).gsub(/[^\w\/#~.-]/) { |char| char.bytes.map { |byte| format("%%%02X", byte) }.join }
      schemer.ref(fragment).validate(data).map { |error| error["error"] }
    end

    # yields every object outside example values, with its path and whether it is a schema
    def each_node(node = document, path = [], schema = false, &block)
      return node.each_with_index { |child, index| each_node(child, path + [ index ], schema, &block) } if node.is_a?(Array)
      return unless node.is_a?(Hash)

      yield node, path, schema
      node.each do |key, value|
        here = path + [ key ]
        if schema
          if SCHEMA_MAPS.include?(key) && value.is_a?(Hash)
            value.each { |name, child| each_node(child, here + [ name ], true, &block) }
          elsif SCHEMA_LISTS.include?(key) || SCHEMA_SINGLES.include?(key)
            each_node(value, here, true, &block)
          end
        elsif path == %w[components schemas] || key == "schema"
          each_node(value, here, true, &block)
        elsif !VALUE_KEYS.include?(key) || NAME_MAPS.include?(path.last)
          each_node(value, here, false, &block)
        end
      end
    end
  end

  # checks every API response of the session against the example's contract
  module CheckedSession
    attr_accessor :openapi_example

    def process(...)
      status = super
      if ApiExceptionsApp::API_PATH.match?(request.path.b)
        message = openapi_example.openapi_contract.check(request, response)
        raise RSpec::Expectations::ExpectationNotMetError, message if message
      end
      status
    end
  end

  def self.contract
    @contract ||= Contract.new(YAML.safe_load_file(SOURCE).freeze)
  end

  # "path: key" for every key a mapping of the YAML source has twice
  def self.duplicate_keys(node, path = [])
    children = node.children.to_a
    return children.flat_map { |child| duplicate_keys(child, path) } unless node.is_a?(Psych::Nodes::Mapping) || node.is_a?(Psych::Nodes::Sequence)
    return children.each_with_index.flat_map { |child, index| duplicate_keys(child, path + [ index ]) } if node.is_a?(Psych::Nodes::Sequence)

    pairs = children.each_slice(2).map { |key, value| [ key.respond_to?(:value) ? key.value : key.to_ruby.to_s, value ] }
    repeated = pairs.map(&:first).tally.select { |_, count| count > 1 }.keys
    repeated.map { |key| "#{path.join('/')}: #{key}" } + pairs.flat_map { |key, value| duplicate_keys(value, path + [ key ]) }
  end

  # the route of every operation: { [ template, verb ] => [ controller class, action ] }
  def self.operation_actions(routes = Rails.application.routes.routes)
    routes.each_with_object({}) do |route, found|
      controller = route.defaults[:controller]
      template = template(route.path.spec.to_s, controller)
      next unless template

      route.verb.to_s.downcase.split("|").each do |verb|
        found[[ template, verb ]] = [ "#{controller}_controller".camelize.constantize, route.defaults[:action] ]
      end
    end
  end

  # route pattern and controller of the route the request matched
  def self.matched_route(request)
    pattern = request.route_uri_pattern
    return [ pattern, request.path_parameters[:controller] ] if pattern

    # a request answered before the router still belongs to its route
    probe = ActionDispatch::Request.new(Rack::MockRequest.env_for(request.path, method: request.method))
    Rails.application.routes.router.recognize(probe) do |route, parameters|
      return [ route.path.spec.to_s, parameters[:controller] ]
    end
    [ nil, nil ]
  rescue ActionController::BadRequest, ArgumentError, URI::InvalidURIError
    [ nil, nil ]
  end

  # document template of a route, nil for the catch-all and for anything outside the API
  def self.template(pattern, controller)
    return if pattern.nil? || controller == CATCH_ALL

    path = pattern.delete_suffix("(.:format)")
    return unless path == PREFIX || path.start_with?("#{PREFIX}/")

    template = path.delete_prefix(PREFIX).gsub(/:(\w+)/, '{\1}')
    template.empty? ? "/" : template
  end

  # [ set of [ template, verb ], routes that cannot be mapped ]
  def self.route_operations(routes = Rails.application.routes.routes)
    operations = Set.new
    problems = []
    routes.each do |route|
      pattern = route.path.spec.to_s
      next unless pattern.match?(%r{\A#{PREFIX}([/(.]|\z)})
      next if route.defaults[:controller] == CATCH_ALL

      template = template(pattern, route.defaults[:controller])
      verbs = route.verb.to_s.downcase.split("|")
      if template&.match?(%r{\A(/|(/(\{\w+\}|[\w.~-]+))+)\z}) && verbs.any? && (verbs - VERBS).empty?
        verbs.each { |verb| operations << [ template, verb ] }
      else
        problems << "cannot map route #{route.verb.presence || 'ANY'} #{pattern} (#{route.defaults[:controller]}##{route.defaults[:action]})"
      end
    end
    [ operations, problems ]
  end

  # true when every API spec file runs and nothing filters the examples
  def self.full_run?(config)
    return false if config.dry_run? || config.only_failures?
    return false unless config.inclusion_filter.rules.empty? && config.exclusion_filter.rules.empty?

    loaded = config.files_to_run.map { |file| File.expand_path(file) }
    (Dir[SPEC_DIR.join("**/*_spec.rb").to_s] - loaded).empty?
  end

  def openapi_contract
    OpenapiHelper.contract
  end

  def create_session(app)
    super.tap do |session|
      session.extend(CheckedSession)
      session.openapi_example = self
    end
  end
end

RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{/spec/requests/api/v1/}) do |metadata|
    metadata[:openapi] = true unless metadata.key?(:openapi)
  end

  config.include OpenapiHelper, openapi: true
end
