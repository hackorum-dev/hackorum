# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Search::QueryValidator, type: :service do
  let(:parser) { Search::QueryParser.new }

  describe '#validate' do
    context 'with valid selectors' do
      it 'passes valid date selectors' do
        ast = parser.parse('first_after:2024-01-01')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
        expect(result.ast).to eq(ast)
      end

      it 'passes valid count selectors' do
        ast = parser.parse('messages:>10')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
        expect(result.ast).to eq(ast)
      end

      it 'passes valid has: selectors' do
        ast = parser.parse('has:attachment')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
      end
    end

    context 'with has:patch progress conditions' do
      def validate(q)
        described_class.new(parser.parse(q)).validate
      end

      it 'keeps valid waiting values' do
        %w[any 2w 2026-01-01].each do |v|
          result = validate("has:patch[waiting:#{v}]")
          expect(result.warnings).to be_empty
          expect(result.ast[:conditions].first[:value]).to eq(v)
        end
      end

      it 'normalizes empty waiting to any' do
        result = validate('has:patch[waiting:]')
        expect(result.warnings).to be_empty
        expect(result.ast[:conditions]).to eq([ { key: :waiting, value: 'any', quoted: false } ])
      end

      it 'drops invalid waiting values' do
        result = validate('has:patch[waiting:soon]')
        expect(result.warnings).to include(/invalid date/i)
        expect(result.ast[:conditions]).to be_nil
      end

      it 'drops after: for attachment' do
        result = validate('has:attachment[after:me]')
        expect(result.warnings).to include(/not valid for/i)
      end
    end

    context 'with empty values' do
      it 'warns and removes selector with empty value' do
        ast = parser.parse('from:')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/empty value/i)
        expect(result.ast).to be_nil
      end

      it 'keeps other valid selectors when one is empty' do
        ast = parser.parse('from: title:postgresql')
        result = described_class.new(ast).validate
        expect(result.warnings.size).to eq(1)
        expect(result.ast[:key]).to eq(:title)
      end
    end

    context 'with invalid date values' do
      it 'warns and removes selector with invalid date' do
        ast = parser.parse('first_after:notadate')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/invalid date/i)
        expect(result.ast).to be_nil
      end
    end

    context 'with invalid count values' do
      it 'warns and removes selector with invalid count' do
        ast = parser.parse('messages:abc')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/invalid count/i)
        expect(result.ast).to be_nil
      end

      it 'warns on negative count' do
        ast = parser.parse('messages:-5')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/invalid count/i)
      end

      it 'accepts valid count operators' do
        [ 'messages:10', 'messages:>10', 'messages:<10', 'messages:>=10', 'messages:<=10' ].each do |query|
          ast = parser.parse(query)
          result = described_class.new(ast).validate
          expect(result.warnings).to be_empty
        end
      end
    end

    context 'with invalid has: values' do
      it 'warns and removes selector with unknown has: value' do
        ast = parser.parse('has:unknown')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/unknown has:/i)
        expect(result.ast).to be_nil
      end
    end

    context 'with tag: selector' do
      it 'passes valid tag name' do
        ast = parser.parse('tag:review')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
        expect(result.ast[:key]).to eq(:tag)
      end

      it 'passes tag name with from: condition' do
        ast = parser.parse('tag:important[from:me]')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
        expect(result.ast[:conditions].size).to eq(1)
      end

      it 'passes tag name with from: team condition' do
        ast = parser.parse('tag:priority[from:reviewers]')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
      end

      it 'passes empty tag name with from: condition' do
        ast = parser.parse('tag:[from:me]')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
      end

      it 'passes tags with dots and dashes' do
        ast = parser.parse('tag:needs-review.v2')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
      end

      it 'passes tag with added_after condition' do
        ast = parser.parse('tag:review[added_after:1w]')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
      end

      it 'passes tag with multiple conditions' do
        ast = parser.parse('tag:review[from:me, added_before:1m]')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
        expect(result.ast[:conditions].size).to eq(2)
      end

      it 'warns on invalid tag format starting with special char' do
        ast = parser.parse('tag:-invalid')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/invalid tag name/i)
        expect(result.ast).to be_nil
      end

      it 'warns on invalid condition for tag selector' do
        ast = parser.parse('tag:review[messages:>=10]')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/not valid for 'tag:'/i)
      end
    end

    context 'with ci:, apply: and group: selectors' do
      def validate(query)
        described_class.new(parser.parse(query)).validate
      end

      it 'accepts ci values case-insensitively' do
        %w[passing failing pending none FAILING].each do |v|
          result = validate("ci:#{v}")
          expect(result.warnings).to be_empty
          expect(result.ast[:key]).to eq(:ci)
        end
      end

      it 'drops invalid ci values' do
        result = validate('ci:bogus')
        expect(result.ast).to be_nil
        expect(result.warnings.join).to include('bogus')
      end

      it 'accepts apply buckets and drops others' do
        PatchCi::BranchHealth::BUCKETS.each { |b| expect(validate("apply:#{b}").ast[:key]).to eq(:apply) }
        result = validate('apply:bogus')
        expect(result.ast).to be_nil
        expect(result.warnings.join).to include('bogus')
      end

      it 'accepts group values and has:group' do
        expect(validate('group:"incremental backup"').ast[:key]).to eq(:group)
        expect(validate('has:group').warnings).to be_empty
      end
    end

    context 'with commit: selector' do
      def validate(query)
        described_class.new(parser.parse(query)).validate
      end

      it 'keeps valid conditions' do
        result = validate('commit:[reviewer:me]')
        expect(result.warnings).to be_empty
        expect(result.ast[:key]).to eq(:commit)
      end

      it 'drops invalid released values' do
        %w[17beta abc].each do |v|
          result = validate("commit:[reviewer:me, released:#{v}]")
          expect(result.ast[:conditions].map { |c| c[:key] }).to eq([ :reviewer ])
          expect(result.warnings.join).to include("Invalid release '#{v}'")
        end
      end

      it 'keeps none and dotted released values' do
        %w[none 8.4].each do |v|
          result = validate("commit:[released:#{v}]")
          expect(result.warnings).to be_empty
          expect(result.ast[:conditions].size).to eq(1)
        end
      end

      it 'drops non-hex and short shas' do
        %w[xyz abc12].each do |v|
          result = validate("commit:#{v}")
          expect(result.ast).to be_nil
          expect(result.warnings.join).to include("must be 7-40 hex characters")
        end
      end

      it 'accepts a hex sha' do
        expect(validate('commit:abc1234').warnings).to be_empty
      end

      it 'rejects count: condition' do
        result = validate('commit:[reviewer:me, count:3]')
        expect(result.ast[:conditions].size).to eq(1)
        expect(result.warnings.join).to include('not valid for')
      end

      it 'accepts new has: values' do
        %w[commit later_fix fixes].each do |v|
          result = validate("has:#{v}")
          expect(result.warnings).to be_empty
          expect(result.ast[:value]).to eq(v)
        end
      end
    end

    context 'with valid commitfest: selector' do
      it 'passes valid commitfest name' do
        ast = parser.parse('commitfest:PG19-Final')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
        expect(result.ast[:key]).to eq(:commitfest)
      end

      it 'passes commitfest name with status: condition' do
        ast = parser.parse('commitfest:PG19-Final[status:commited]')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
        expect(result.ast[:conditions].size).to eq(1)
      end

      it 'passes commitfest name with tag: condition' do
        ast = parser.parse('commitfest:PG19-Final[tag:commited]')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
        expect(result.ast[:conditions].size).to eq(1)
      end

      it 'passes commitfest with multiple conditions' do
        ast = parser.parse('commitfest:PG19-Draft[status:in_progress, tag:bugfix]')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
        expect(result.ast[:conditions].size).to eq(2)
      end

      it 'warns on invalid condition for commitfest selector' do
        ast = parser.parse('commitfest:[messages:>=10]')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/not valid for 'commitfest:'/i)
      end
    end

    context 'with bracket-only keys and short selectors as plain text' do
      def warnings_for(query)
        described_class.new(parser.parse(query)).validate.warnings
      end

      it 'warns that reviewer: only works inside commit:[...]' do
        expect(warnings_for('reviewer:me').join).to include("'reviewer:' works inside commit:[...]")
      end

      it 'names the parent for after: and does not suggest first_after:' do
        warnings = warnings_for('after:me')
        expect(warnings.join).to include("'after:' works inside has:patch[...]")
        expect(warnings.join).not_to include('first_after')
      end

      it 'does not suggest ci: for circle:x' do
        expect(warnings_for('circle:x').join).not_to include("'ci:'")
      end

      it 'still suggests ci: for a near typo' do
        expect(warnings_for('cl:x').join).to include("'ci:'")
      end
    end

    context 'with compound expressions' do
      it 'validates children of AND expressions' do
        ast = parser.parse('from:john first_after:invalid')
        result = described_class.new(ast).validate
        expect(result.warnings.size).to eq(1)
        expect(result.ast[:key]).to eq(:from)
      end

      it 'validates children of OR expressions' do
        ast = parser.parse('first_after:invalid OR from:john')
        result = described_class.new(ast).validate
        expect(result.warnings.size).to eq(1)
        expect(result.ast[:key]).to eq(:from)
      end

      it 'returns nil when all children are invalid' do
        ast = parser.parse('first_after:invalid messages:abc')
        result = described_class.new(ast).validate
        expect(result.warnings.size).to eq(2)
        expect(result.ast).to be_nil
      end
    end

    context 'with nil AST' do
      it 'returns empty result' do
        result = described_class.new(nil).validate
        expect(result.ast).to be_nil
        expect(result.warnings).to be_empty
      end
    end

    context 'with selector-like typos in text' do
      it 'warns about typo similar to last_before' do
        ast = parser.parse('lasxt_before:1y')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/looks like a selector.*last_before/i)
        # The text node is still kept for searching
        expect(result.ast[:type]).to eq(:text)
      end

      it 'warns about typo similar to first_after' do
        ast = parser.parse('fist_after:2024')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/looks like a selector.*first_after/i)
      end

      it 'warns about typo similar to from' do
        ast = parser.parse('frm:john')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/looks like a selector.*from/i)
      end

      it 'warns about unknown selector containing common patterns' do
        ast = parser.parse('readby:me')
        result = described_class.new(ast).validate
        # readby is close to 'read', so it gets the "Did you mean" suggestion
        expect(result.warnings).to include(/looks like a selector.*read/i)
      end

      it 'warns generically about selector-like patterns without close matches' do
        # Use a word that contains a pattern like 'content' but is far from all selectors
        ast = parser.parse('mycontent:test')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/not a recognized selector/i)
      end

      it 'does not warn about regular text with colons like URLs' do
        ast = parser.parse('https://example.com')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
      end

      it 'does not warn about quoted text that looks like a selector typo' do
        ast = parser.parse('"activxe_before:1y"')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
      end

      it 'does not warn about quoted text in complex queries' do
        ast = parser.parse('starter:me OR (from:john "activxe_before:1y")')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
      end

      it 'does not warn about text without colons' do
        ast = parser.parse('postgresql')
        result = described_class.new(ast).validate
        expect(result.warnings).to be_empty
      end

      it 'warns about misspelled selector in complex query' do
        ast = parser.parse('starter:me OR (from:john lasxt_before:1y)')
        result = described_class.new(ast).validate
        expect(result.warnings).to include(/lasxt_before.*looks like a selector/i)
      end

      it 'suggests multiple similar selectors when applicable' do
        ast = parser.parse('firs:2024')
        result = described_class.new(ast).validate
        # Should suggest first_after and/or first_before
        expect(result.warnings.first).to include('first_after').or include('first_before')
      end
    end
  end

  it 'keeps the negation when a negated group collapses to one child' do
    ast = parser.parse('-(has:xyz foo)')
    result = described_class.new(ast).validate
    expect(result.ast).to include(type: :text, value: 'foo', negated: true)
  end
end
