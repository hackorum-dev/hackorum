# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Search::QueryParser, type: :service do
  let(:parser) { described_class.new }

  describe '#parse' do
    context 'with simple text' do
      it 'parses a single word' do
        result = parser.parse('postgresql')
        expect(result[:type]).to eq(:text)
        expect(result[:value]).to eq('postgresql')
        expect(result[:negated]).to be false
      end

      it 'parses bracketed text as plain text' do
        result = parser.parse('[proposal] plan')
        expect(result[:type]).to eq(:and)
        expect(result[:children].size).to eq(2)
        expect(result[:children][0][:type]).to eq(:text)
        expect(result[:children][0][:value]).to eq('[proposal]')
        expect(result[:children][1][:value]).to eq('plan')
      end

      it 'parses multiple words as implicit AND' do
        result = parser.parse('postgresql vacuum')
        expect(result[:type]).to eq(:and)
        expect(result[:children].size).to eq(2)
        expect(result[:children][0][:value]).to eq('postgresql')
        expect(result[:children][1][:value]).to eq('vacuum')
      end

      it 'parses quoted text' do
        result = parser.parse('"query planning"')
        expect(result[:type]).to eq(:text)
        expect(result[:value]).to eq('query planning')
        expect(result[:quoted]).to be true
      end
    end

    context 'with selectors' do
      it 'parses from: selector' do
        result = parser.parse('from:john')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:from)
        expect(result[:value]).to eq('john')
        expect(result[:negated]).to be false
      end

      it 'parses title: selector with quoted value' do
        result = parser.parse('title:"query planning"')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:title)
        expect(result[:value]).to eq('query planning')
        expect(result[:quoted]).to be true
      end

      it 'parses all date selectors' do
        %w[first_after first_before messages_after messages_before last_after last_before].each do |selector|
          result = parser.parse("#{selector}:2024-01-01")
          expect(result[:type]).to eq(:selector)
          expect(result[:key]).to eq(selector.to_sym)
        end
      end

      it 'parses all state selectors' do
        %w[unread read reading new starred notes].each do |selector|
          result = parser.parse("#{selector}:me")
          expect(result[:type]).to eq(:selector)
          expect(result[:key]).to eq(selector.to_sym)
          expect(result[:value]).to eq('me')
        end
      end

      it 'parses count selectors' do
        %w[messages participants contributors].each do |selector|
          result = parser.parse("#{selector}:>10")
          expect(result[:type]).to eq(:selector)
          expect(result[:key]).to eq(selector.to_sym)
          expect(result[:value]).to eq('>10')
        end
      end

      it 'parses has: selector' do
        result = parser.parse('has:attachment')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:has)
        expect(result[:value]).to eq('attachment')
      end

      it 'parses tag: selector' do
        result = parser.parse('tag:review')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:tag)
        expect(result[:value]).to eq('review')
      end

      it 'parses tag: selector with from: condition' do
        result = parser.parse('tag:review[from:me]')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:tag)
        expect(result[:value]).to eq('review')
        expect(result[:conditions].size).to eq(1)
        expect(result[:conditions][0][:key]).to eq(:from)
        expect(result[:conditions][0][:value]).to eq('me')
      end

      it 'parses tag: selector with empty value and from: condition' do
        result = parser.parse('tag:[from:me]')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:tag)
        expect(result[:value]).to eq('')
        expect(result[:conditions].size).to eq(1)
      end

      it 'parses commitfest: selector' do
        result = parser.parse('commitfest:PG19-Final')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:commitfest)
        expect(result[:value]).to eq('PG19-Final')
      end

      it 'parses commitfest: selector with status: condition' do
        result = parser.parse('commitfest:PG19-Draft[status:commited]')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:commitfest)
        expect(result[:value]).to eq('PG19-Draft')
        expect(result[:conditions].size).to eq(1)
        expect(result[:conditions][0][:key]).to eq(:status)
        expect(result[:conditions][0][:value]).to eq('commited')
      end

      it 'parses commitfest: selector with empty value and from: condition' do
        result = parser.parse('commitfest:[tag:bugfix]')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:commitfest)
        expect(result[:value]).to eq('')
        expect(result[:conditions].size).to eq(1)
      end
    end

    context 'with negation' do
      it 'parses negated text' do
        result = parser.parse('-spam')
        expect(result[:type]).to eq(:text)
        expect(result[:negated]).to be true
        expect(result[:value]).to eq('spam')
      end

      it 'parses negated selector' do
        result = parser.parse('-from:john')
        expect(result[:type]).to eq(:selector)
        expect(result[:negated]).to be true
        expect(result[:key]).to eq(:from)
        expect(result[:value]).to eq('john')
      end

      it 'parses negated has: selector' do
        result = parser.parse('-has:contributor')
        expect(result[:type]).to eq(:selector)
        expect(result[:negated]).to be true
        expect(result[:key]).to eq(:has)
        expect(result[:value]).to eq('contributor')
      end
    end

    context 'with boolean operators' do
      it 'parses explicit OR' do
        result = parser.parse('from:john OR from:jane')
        expect(result[:type]).to eq(:or)
        expect(result[:children].size).to eq(2)
        expect(result[:children][0][:value]).to eq('john')
        expect(result[:children][1][:value]).to eq('jane')
      end

      it 'parses case-insensitive OR' do
        result = parser.parse('from:john or from:jane')
        expect(result[:type]).to eq(:or)
      end

      it 'parses mixed-case OR' do
        result = parser.parse('from:john Or from:jane')
        expect(result[:type]).to eq(:or)
      end

      it 'parses mixed-case AND' do
        result = parser.parse('from:john And unread:me')
        expect(result[:type]).to eq(:and)
        expect(result[:children].size).to eq(2)
      end

      it 'parses explicit AND' do
        result = parser.parse('from:john AND unread:me')
        expect(result[:type]).to eq(:and)
        expect(result[:children].size).to eq(2)
      end

      it 'handles operator precedence (AND binds tighter than OR)' do
        result = parser.parse('from:john unread:me OR from:jane')
        expect(result[:type]).to eq(:or)
        # First child should be the AND of john and unread:me
        expect(result[:children][0][:type]).to eq(:and)
        # Second child should be jane
        expect(result[:children][1][:value]).to eq('jane')
      end
    end

    context 'with parentheses' do
      it 'parses grouped expression' do
        result = parser.parse('(from:john OR from:jane) unread:me')
        expect(result[:type]).to eq(:and)
        expect(result[:children][0][:type]).to eq(:or)
        expect(result[:children][1][:key]).to eq(:unread)
      end

      it 'parses negated grouped expression' do
        result = parser.parse('-(from:john OR from:jane)')
        expect(result[:type]).to eq(:or)
        expect(result[:negated]).to be true
      end
    end

    context 'with complex queries' do
      it 'parses complex query with multiple selectors' do
        result = parser.parse('from:john title:"postgresql" unread:me')
        expect(result[:type]).to eq(:and)
        expect(result[:children].size).to eq(3)
      end

      it 'parses query with mixed text and selectors' do
        result = parser.parse('postgresql from:john vacuum')
        expect(result[:type]).to eq(:and)
        expect(result[:children].size).to eq(3)
      end
    end

    context 'with dependent conditions (bracket notation)' do
      it 'parses from: selector with single condition' do
        result = parser.parse('from:bruce[messages:>=10]')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:from)
        expect(result[:value]).to eq('bruce')
        expect(result[:conditions]).to be_an(Array)
        expect(result[:conditions].size).to eq(1)
        expect(result[:conditions][0][:key]).to eq(:messages)
        expect(result[:conditions][0][:value]).to eq('>=10')
      end

      it 'parses from: selector with multiple conditions' do
        result = parser.parse('from:bruce[messages:>=10, last_before:1m]')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:from)
        expect(result[:conditions].size).to eq(2)
        expect(result[:conditions][0][:key]).to eq(:messages)
        expect(result[:conditions][0][:value]).to eq('>=10')
        expect(result[:conditions][1][:key]).to eq(:last_before)
        expect(result[:conditions][1][:value]).to eq('1m')
      end

      it 'parses from: selector with body condition' do
        result = parser.parse('from:bruce[body:"patch"]')
        expect(result[:conditions].size).to eq(1)
        expect(result[:conditions][0][:key]).to eq(:body)
        expect(result[:conditions][0][:value]).to eq('patch')
        expect(result[:conditions][0][:quoted]).to be true
      end

      it 'parses has:attachment with conditions' do
        result = parser.parse('has:attachment[from:bruce,count:>=3]')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:has)
        expect(result[:value]).to eq('attachment')
        expect(result[:conditions].size).to eq(2)
        expect(result[:conditions][0][:key]).to eq(:from)
        expect(result[:conditions][0][:value]).to eq('bruce')
        expect(result[:conditions][1][:key]).to eq(:count)
        expect(result[:conditions][1][:value]).to eq('>=3')
      end

      it 'parses tag: selector with from condition' do
        result = parser.parse('tag:important[from:me]')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:tag)
        expect(result[:value]).to eq('important')
        expect(result[:conditions].size).to eq(1)
        expect(result[:conditions][0][:key]).to eq(:from)
        expect(result[:conditions][0][:value]).to eq('me')
      end

      it 'parses tag: selector with empty value and condition' do
        result = parser.parse('tag:[from:teamname]')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:tag)
        expect(result[:value]).to eq('')
        expect(result[:conditions].size).to eq(1)
        expect(result[:conditions][0][:key]).to eq(:from)
      end

      it 'parses negated selector with conditions' do
        result = parser.parse('-from:bruce[messages:>=10]')
        expect(result[:type]).to eq(:selector)
        expect(result[:negated]).to be true
        expect(result[:key]).to eq(:from)
        expect(result[:value]).to eq('bruce')
        expect(result[:conditions].size).to eq(1)
      end

      it 'parses selector without conditions' do
        result = parser.parse('from:bruce')
        expect(result[:conditions]).to be_nil
      end

      it 'handles whitespace in condition list' do
        result = parser.parse('from:bruce[ messages:>=10 , last_before:1m ]')
        expect(result[:conditions].size).to eq(2)
        expect(result[:conditions][0][:key]).to eq(:messages)
        expect(result[:conditions][1][:key]).to eq(:last_before)
      end

      it 'parses has:patch with conditions' do
        result = parser.parse('has:patch[from:tom,count:>=2]')
        expect(result[:key]).to eq(:has)
        expect(result[:value]).to eq('patch')
        expect(result[:conditions].size).to eq(2)
      end

      it 'parses tag with added_before condition' do
        result = parser.parse('tag:review[added_before:1w]')
        expect(result[:conditions].size).to eq(1)
        expect(result[:conditions][0][:key]).to eq(:added_before)
        expect(result[:conditions][0][:value]).to eq('1w')
      end
    end

    context 'with edge cases' do
      it 'returns nil for blank query' do
        expect(parser.parse('')).to be_nil
        expect(parser.parse('   ')).to be_nil
        expect(parser.parse(nil)).to be_nil
      end

      it 'handles selector with empty value' do
        result = parser.parse('from:')
        expect(result[:type]).to eq(:selector)
        expect(result[:key]).to eq(:from)
        expect(result[:value]).to eq('')
      end

      it 'handles emails in from selector' do
        result = parser.parse('from:john@example.com')
        expect(result[:type]).to eq(:selector)
        expect(result[:value]).to eq('john@example.com')
      end
    end
  end

  describe '#valid?' do
    it 'returns true for valid queries' do
      expect(parser.valid?('from:john')).to be true
      expect(parser.valid?('postgresql vacuum')).to be true
      expect(parser.valid?('(from:john OR from:jane)')).to be true
    end

    it 'returns false for invalid syntax' do
      expect(parser.valid?('((broken')).to be false
      # Note: 'from:john OR OR' is valid - the second OR is parsed as plain text
    end
  end
end
