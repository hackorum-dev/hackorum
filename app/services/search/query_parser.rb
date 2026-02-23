# frozen_string_literal: true

require "parslet"

module Search
  # Parses search query strings into an AST using Parslet.
  # Supports selectors (from:, title:, etc.), boolean operators (AND, OR),
  # grouping with parentheses, and negation with minus prefix.
  class QueryParser
    class Grammar < Parslet::Parser
      # Basic whitespace
      rule(:space) { match('\s').repeat(1) }
      rule(:space?) { space.maybe }

      # Quoted strings
      rule(:double_quoted) do
        str('"') >>
          (str("\\") >> any | str('"').absent? >> any).repeat.as(:dq_content) >>
          str('"')
      end

      # Word characters (no spaces, parens, quotes, colons at end, no brackets for dependent conditions)
      rule(:word_char) { match('[^\s()":,\[\]]') }

      # A word - sequence of word chars, may contain internal colons (like URLs)
      rule(:word) do
        (word_char >> (word_char | str(":") >> word_char.present?).repeat).as(:word)
      end

      # Bracketed text (treated as plain text, not dependent conditions)
      rule(:bracketed_text) do
        str("[") >> (str("]").absent? >> any).repeat.as(:bracketed_content) >> str("]")
      end

      # Selector keywords - IMPORTANT: longer strings must come before shorter prefixes
      # e.g., "reading" before "read", "messages_after" before "messages"
      rule(:selector_key) do
        (
          str("first_after") | str("first_before") |
          str("messages_after") | str("messages_before") |
          str("last_after") | str("last_before") |
          str("last_from") | str("from") | str("starter") |
          str("title") | str("body") |
          str("contributors") | str("participants") | str("messages") |
          str("unread") | str("reading") | str("read") | str("new") |
          str("starred") | str("notes") | str("tag") |
          str("has") | str("commitfest")
        ).as(:selector_key)
      end

      # Selector value (quoted or unquoted)
      rule(:selector_value) do
        double_quoted | word
      end

      # Sub-condition keywords for dependent conditions within brackets
      rule(:condition_key) do
        (
          str("last_after") | str("last_before") |
          str("first_after") | str("first_before") |
          str("added_after") | str("added_before") |
          str("messages") | str("count") | str("from") |
          str("body") | str("name") | str("status") | str("tag")
        ).as(:condition_key)
      end

      # Condition value - similar to selector_value but stops at comma or bracket
      rule(:condition_value_char) { match('[^\s,\]":]') }
      rule(:condition_value_word) do
        (condition_value_char >> (condition_value_char | str(":") >> condition_value_char.present?).repeat).as(:cond_word)
      end
      rule(:condition_value) do
        double_quoted | condition_value_word
      end

      # Single condition: key:value
      rule(:condition) do
        condition_key >> str(":") >> condition_value.maybe.as(:condition_value)
      end

      # Comma-separated condition list in brackets
      rule(:dependent_conditions) do
        str("[") >> space? >>
        condition.as(:first_cond) >>
        (space? >> str(",") >> space? >> condition).repeat.as(:more_conds) >>
        space? >> str("]")
      end

      # Full selector: key:value with optional dependent conditions
      rule(:selector) do
        selector_key >> str(":") >> selector_value.maybe.as(:selector_value) >>
        dependent_conditions.maybe.as(:conditions)
      end

      # Grouped expression
      rule(:grouped) do
        str("(") >> space? >> or_expression >> space? >> str(")")
      end

      # Negation
      rule(:neg) { str("-") }

      # Atomic term: selector, grouped, quoted text, or plain word
      rule(:atom) do
        selector.as(:selector) |
        grouped |
        bracketed_text.as(:bracketed_text) |
        double_quoted.as(:quoted_text) |
        word.as(:plain_text)
      end

      # Term can be negated
      rule(:term) do
        (neg.as(:negation) >> atom.as(:inner)).as(:negated) |
        atom
      end

      # AND operator (explicit only - implicit handled separately)
      # Case-insensitive matching for boolean operators
      rule(:and_keyword) { (str("A") | str("a")) >> (str("N") | str("n")) >> (str("D") | str("d")) }
      rule(:or_keyword) { (str("O") | str("o")) >> (str("R") | str("r")) }

      # AND expression: terms joined by AND or space (implicit AND)
      rule(:and_expression) do
        (term.as(:first) >>
          (space >> and_keyword >> space >> term | space >> or_keyword.absent? >> term).repeat.as(:more)
        ).as(:and_sequence)
      end

      # OR expression: and_expressions joined by OR
      rule(:or_expression) do
        (and_expression.as(:first) >>
          (space >> or_keyword >> space >> and_expression).repeat.as(:more)
        ).as(:or_sequence)
      end

      # Root
      rule(:query) { space? >> or_expression.maybe >> space? }

      root(:query)
    end

    class Transform < Parslet::Transform
      # Word to string
      rule(word: simple(:w)) { w.to_s }

      # Condition value word to string
      rule(cond_word: simple(:w)) { w.to_s }

      # Double-quoted content
      rule(dq_content: simple(:c)) { { quoted_content: c.to_s } }
      rule(dq_content: sequence(:c)) { { quoted_content: c.map(&:to_s).join } }

      # Plain text node
      rule(plain_text: simple(:t)) do
        { type: :text, value: t.to_s, negated: false, quoted: false }
      end

      # Quoted text node
      rule(quoted_text: { quoted_content: simple(:c) }) do
        { type: :text, value: c.to_s, negated: false, quoted: true }
      end

      # Bracketed text node
      rule(bracketed_text: { bracketed_content: simple(:c) }) do
        { type: :text, value: "[#{c}]", negated: false, quoted: false }
      end
      rule(bracketed_text: { bracketed_content: sequence(:c) }) do
        { type: :text, value: "[#{c.map(&:to_s).join}]", negated: false, quoted: false }
      end

      # Selector with value and optional conditions
      rule(selector: { selector_key: simple(:k), selector_value: subtree(:v), conditions: subtree(:conds) }) do
        val = case v
        when String then v
        when Hash then v[:quoted_content] || v[:value] || ""
        when nil then ""
        else v.to_s
        end
        quoted = v.is_a?(Hash) && v.key?(:quoted_content)

        # Parse conditions if present
        conditions = Transform.parse_conditions(conds)

        {
          type: :selector,
          key: k.to_s.to_sym,
          value: val,
          negated: false,
          quoted: quoted,
          conditions: conditions
        }
      end

      # Selector without conditions (backwards compatibility)
      rule(selector: { selector_key: simple(:k), selector_value: subtree(:v) }) do
        val = case v
        when String then v
        when Hash then v[:quoted_content] || v[:value] || ""
        when nil then ""
        else v.to_s
        end
        quoted = v.is_a?(Hash) && v.key?(:quoted_content)
        { type: :selector, key: k.to_s.to_sym, value: val, negated: false, quoted: quoted, conditions: nil }
      end

      # Selector without value
      rule(selector: { selector_key: simple(:k), selector_value: nil }) do
        { type: :selector, key: k.to_s.to_sym, value: "", negated: false, quoted: false, conditions: nil }
      end

      # Helper to parse conditions from raw Parslet output
      def self.parse_conditions(conds)
        return nil if conds.nil? || conds == [] || conds == ""

        conditions = []

        # Handle first_cond
        if conds.is_a?(Hash) && conds[:first_cond]
          conditions << parse_single_condition(conds[:first_cond])

          # Handle more_conds
          more = conds[:more_conds]
          if more.is_a?(Array)
            more.each do |c|
              conditions << parse_single_condition(c)
            end
          elsif more.is_a?(Hash)
            conditions << parse_single_condition(more)
          end
        end

        conditions.empty? ? nil : conditions
      end

      def self.parse_single_condition(cond)
        return nil unless cond.is_a?(Hash)

        key = cond[:condition_key]&.to_s&.to_sym
        raw_value = cond[:condition_value]

        value = case raw_value
        when String then raw_value
        when Hash then raw_value[:quoted_content] || raw_value[:value] || ""
        when nil then ""
        else raw_value.to_s
        end

        quoted = raw_value.is_a?(Hash) && raw_value.key?(:quoted_content)

        { key: key, value: value, quoted: quoted }
      end

      # Negated term
      rule(negated: { negation: simple(:_), inner: subtree(:inner) }) do
        if inner.is_a?(Hash) && inner[:type]
          inner.merge(negated: true)
        else
          { type: :text, value: inner.to_s, negated: true, quoted: false }
        end
      end

      # AND sequence
      rule(and_sequence: { first: subtree(:first), more: subtree(:more) }) do
        items = [ first ] + Array(more)
        items = items.flatten.compact.reject { |x| x == {} || x == "" }
        items.size == 1 ? items.first : { type: :and, children: items }
      end

      # OR sequence
      rule(or_sequence: { first: subtree(:first), more: subtree(:more) }) do
        items = [ first ] + Array(more)
        items = items.flatten.compact.reject { |x| x == {} || x == "" }
        items.size == 1 ? items.first : { type: :or, children: items }
      end
    end

    def initialize
      @grammar = Grammar.new
      @transform = Transform.new
    end

    def parse(query_string)
      return nil if query_string.blank?

      tree = @grammar.parse(query_string)
      ast = @transform.apply(tree)

      return nil if ast.nil? || ast == "" || ast == {}

      normalize_ast(ast)
    end

    def valid?(query_string)
      parse(query_string)
      true
    rescue Parslet::ParseFailed
      false
    end

    private

    def normalize_ast(node)
      return node unless node.is_a?(Hash)

      if node[:type] == :and || node[:type] == :or
        children = node[:children].map { |c| normalize_ast(c) }
        children = children.flat_map do |c|
          if c.is_a?(Hash) && c[:type] == node[:type]
            c[:children]
          else
            [ c ]
          end
        end
        children = children.compact.reject { |c| c == {} }

        return children.first if children.size == 1
        return nil if children.empty?

        node.merge(children: children)
      else
        node
      end
    end
  end
end
