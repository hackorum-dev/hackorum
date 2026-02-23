# frozen_string_literal: true

module Search
  # Validates AST nodes and collects warnings.
  # Does not fail on invalid values - just warns and marks nodes to skip.
  class QueryValidator
    Result = Struct.new(:ast, :warnings, keyword_init: true)

    DATE_SELECTORS = %i[
      first_after first_before
      messages_after messages_before
      last_after last_before
    ].freeze

    COUNT_SELECTORS = %i[messages participants contributors].freeze

    AUTHOR_SELECTORS = %i[from starter last_from].freeze

    STATE_SELECTORS = %i[unread read reading new starred notes].freeze

    CONTENT_SELECTORS = %i[title body].freeze

    TAG_SELECTORS = %i[tag].freeze

    COMMITFEST_SELECTORS = %i[commitfest]

    ALL_SELECTORS = (DATE_SELECTORS + COUNT_SELECTORS + AUTHOR_SELECTORS +
                     STATE_SELECTORS + CONTENT_SELECTORS + TAG_SELECTORS +
                     COMMITFEST_SELECTORS + [ :has ]).freeze

    HAS_VALUES = %w[attachment patch contributor committer core_team commitfest].freeze

    # Valid sub-conditions for each parent selector
    VALID_SUB_CONDITIONS = {
      from: %i[messages last_before last_after first_before first_after body],
      has: {
        attachment: %i[from count name],
        patch: %i[from count]
      },
      tag: %i[from added_before added_after],
      commitfest: %i[name status tag]
    }.freeze

    # Sub-condition keywords that require date values
    DATE_SUB_CONDITIONS = %i[last_before last_after first_before first_after added_before added_after].freeze

    # Sub-condition keywords that require count values
    COUNT_SUB_CONDITIONS = %i[messages count].freeze

    def initialize(ast)
      @ast = ast
      @warnings = []
    end

    def validate
      return Result.new(ast: nil, warnings: []) if @ast.nil?

      validated_ast = validate_node(@ast)
      Result.new(ast: validated_ast, warnings: @warnings)
    end

    private

    def validate_node(node)
      return nil if node.nil?

      case node[:type]
      when :and, :or
        validate_compound(node)
      when :selector
        validate_selector(node)
      when :text
        validate_text(node)
      else
        node
      end
    end

    def validate_compound(node)
      children = node[:children].map { |c| validate_node(c) }.compact
      return nil if children.empty?
      return children.first if children.size == 1

      node.merge(children: children)
    end

    def validate_selector(node)
      key = node[:key]
      value = node[:value].to_s

      # Check for empty value (except for selectors that support conditions only)
      if value.blank? && !supports_empty_value_with_conditions?(key, node[:conditions])
        @warnings << "Empty value for '#{key}:' selector was ignored"
        return nil
      end

      # Validate based on selector type
      validated = case key
      when *DATE_SELECTORS
                    validate_date_selector(node)
      when *COUNT_SELECTORS
                    validate_count_selector(node)
      when *AUTHOR_SELECTORS
                    validate_author_selector(node)
      when *STATE_SELECTORS
                    validate_state_selector(node)
      when *CONTENT_SELECTORS
                    validate_content_selector(node)
      when *TAG_SELECTORS
                    validate_tag_selector(node)
      when *COMMITFEST_SELECTORS
                    validate_commitfest_selector(node)
      when :has
                    validate_has_selector(node)
      else
                    @warnings << "Unknown selector '#{key}:' was ignored"
                    nil
      end

      return nil unless validated

      # Validate conditions if present
      if node[:conditions].present?
        validated_conditions = validate_conditions(key, value, node[:conditions])
        return validated.merge(conditions: validated_conditions)
      end

      validated
    end

    def supports_empty_value_with_conditions?(key, conditions)
      # tag: and commitfest: can have empty value with conditions (e.g., tag:[from:me], commitfest:[tag:bugfix])
      key.in?([ :tag, :commitfest ]) && conditions.present?
    end

    def validate_conditions(parent_key, parent_value, conditions)
      valid_conditions = []

      conditions.each do |cond|
        validated = validate_single_condition(parent_key, parent_value, cond)
        valid_conditions << validated if validated
      end

      valid_conditions.empty? ? nil : valid_conditions
    end

    def validate_single_condition(parent_key, parent_value, cond)
      cond_key = cond[:key]
      cond_value = cond[:value].to_s

      # Check if this condition is valid for the parent selector
      valid_keys = get_valid_sub_conditions(parent_key, parent_value)
      unless valid_keys.include?(cond_key)
        @warnings << "Condition '#{cond_key}:' is not valid for '#{parent_key}:' selector - ignored"
        return nil
      end

      # Validate the condition value
      if cond_value.blank?
        @warnings << "Empty value for condition '#{cond_key}:' was ignored"
        return nil
      end

      # Validate based on condition type
      if DATE_SUB_CONDITIONS.include?(cond_key)
        parser = DateParser.new(cond_value)
        unless parser.valid?
          @warnings << "Invalid date '#{cond_value}' for condition '#{cond_key}:' was ignored"
          return nil
        end
      elsif COUNT_SUB_CONDITIONS.include?(cond_key)
        unless cond_value.match?(/\A(>|<|>=|<=)?(\d+)\z/)
          @warnings << "Invalid count '#{cond_value}' for condition '#{cond_key}:' was ignored"
          return nil
        end
      end

      cond
    end

    def get_valid_sub_conditions(parent_key, parent_value)
      case parent_key
      when :from
        VALID_SUB_CONDITIONS[:from] || []
      when :has
        has_conditions = VALID_SUB_CONDITIONS[:has]
        normalized_value = parent_value.to_s.downcase.to_sym
        has_conditions[normalized_value] || []
      when :tag
        VALID_SUB_CONDITIONS[:tag] || []
      when :commitfest
        VALID_SUB_CONDITIONS[:commitfest] || []
      else
        []
      end
    end

    def validate_date_selector(node)
      value = node[:value]
      parser = DateParser.new(value)

      unless parser.valid?
        @warnings << "Invalid date '#{value}' for '#{node[:key]}:' was ignored"
        return nil
      end

      node
    end

    def validate_count_selector(node)
      value = node[:value].to_s

      # Parse count value: N, >N, <N, >=N, <=N
      unless value.match?(/\A(>|<|>=|<=)?(\d+)\z/)
        @warnings << "Invalid count '#{value}' for '#{node[:key]}:' was ignored"
        return nil
      end

      # Extract the number to check it's valid
      number = value.gsub(/[<>=]/, "").to_i
      if number < 0
        @warnings << "Negative count '#{value}' for '#{node[:key]}:' was ignored"
        return nil
      end

      node
    end

    def validate_author_selector(node)
      # Author selectors accept any non-empty value
      # ValueResolver will handle the actual resolution and generate its own warnings
      node
    end

    def validate_state_selector(node)
      # State selectors require 'me' or a team name
      # Actual validation happens in ValueResolver
      node
    end

    def validate_content_selector(node)
      # Content selectors (title:, body:) accept any non-empty value
      # The value is passed to PostgreSQL FTS
      node
    end

    def validate_tag_selector(node)
      value = node[:value].to_s

      # Tag value can be empty (with conditions like tag:[from:me]) or a simple tag name
      # Tag names must match NoteTag format: starts with alphanumeric, can contain alphanumerics, _, ., -
      if value.present?
        tag_pattern = /\A[a-z0-9][a-z0-9_.\-]*\z/i
        unless value.match?(tag_pattern)
          @warnings << "Invalid tag name '#{value}' - tag names must start with alphanumeric"
          return nil
        end
      end

      node
    end

    def validate_commitfest_selector(node)
      node
    end

    def validate_has_selector(node)
      value = node[:value].to_s.downcase

      unless HAS_VALUES.include?(value)
        @warnings << "Unknown has: value '#{value}' - valid values are: #{HAS_VALUES.join(', ')}"
        return nil
      end

      node
    end

    def validate_text(node)
      value = node[:value].to_s

      # Don't check quoted text for selector typos - user explicitly quoted it
      return node if node[:quoted]

      # Check if text looks like a selector (word:something)
      if value.match?(/\A[a-z_]+:[^\s]*\z/i)
        potential_key = value.split(":").first.downcase
        check_for_selector_typo(potential_key, value)
      end

      node
    end

    def check_for_selector_typo(potential_key, full_value)
      # Skip if it's a known selector (shouldn't happen, but safety check)
      return if ALL_SELECTORS.include?(potential_key.to_sym)

      # Find similar selectors using Levenshtein-like matching
      similar = find_similar_selectors(potential_key)

      if similar.any?
        suggestions = similar.map { |s| "'#{s}:'" }.join(", ")
        @warnings << "'#{full_value}' looks like a selector but '#{potential_key}:' is not recognized. " \
                     "Did you mean #{suggestions}? It will be searched as plain text."
      elsif looks_like_selector_typo?(potential_key)
        # If it contains common selector-like patterns, warn generically
        @warnings << "'#{potential_key}:' is not a recognized selector. " \
                     "It will be searched as plain text. See search help for valid selectors."
      end
    end

    def find_similar_selectors(potential_key)
      ALL_SELECTORS.select do |selector|
        selector_str = selector.to_s
        # Check for close match using simple edit distance heuristics
        levenshtein_distance(potential_key, selector_str) <= 2 ||
          potential_key.include?(selector_str) ||
          selector_str.include?(potential_key)
      end.map(&:to_s)
    end

    def looks_like_selector_typo?(key)
      # Common patterns that suggest user intended a selector
      patterns = %w[
        from to by
        after before
        title body content text
        read unread
        star note tag
        has message participant contributor
        active sent started
      ]

      patterns.any? { |p| key.include?(p) }
    end

    def levenshtein_distance(s1, s2)
      m, n = s1.length, s2.length
      return n if m.zero?
      return m if n.zero?

      # Use simple array instead of matrix for memory efficiency
      prev_row = (0..n).to_a
      curr_row = []

      (1..m).each do |i|
        curr_row[0] = i
        (1..n).each do |j|
          cost = s1[i - 1] == s2[j - 1] ? 0 : 1
          curr_row[j] = [
            prev_row[j] + 1,       # deletion
            curr_row[j - 1] + 1,   # insertion
            prev_row[j - 1] + cost # substitution
          ].min
        end
        prev_row = curr_row.dup
      end

      curr_row[n]
    end
  end
end
