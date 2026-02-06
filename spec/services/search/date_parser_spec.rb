# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Search::DateParser, type: :service do
  describe '#parse' do
    context 'with absolute dates' do
      it 'parses full date format (YYYY-MM-DD)' do
        result = described_class.new('2024-01-15').parse
        expect(result).to eq(Time.zone.parse('2024-01-15 00:00:00'))
      end

      it 'parses month format (YYYY-MM)' do
        result = described_class.new('2024-01').parse
        expect(result).to eq(Time.zone.parse('2024-01-01 00:00:00'))
      end

      it 'parses year format (YYYY)' do
        result = described_class.new('2024').parse
        expect(result).to eq(Time.zone.parse('2024-01-01 00:00:00'))
      end

      it 'parses ISO timestamp' do
        result = described_class.new('2024-01-15T10:30:00').parse
        expect(result).to eq(Time.zone.parse('2024-01-15 10:30:00'))
      end
    end

    context 'with relative dates' do
      around do |example|
        travel_to(Time.zone.parse('2024-06-15 12:00:00')) { example.run }
      end

      it 'parses today' do
        result = described_class.new('today').parse
        expect(result).to eq(Time.zone.parse('2024-06-15 00:00:00'))
      end

      it 'parses yesterday' do
        result = described_class.new('yesterday').parse
        expect(result).to eq(Time.zone.parse('2024-06-14 00:00:00'))
      end

      it 'parses days ago (7d)' do
        result = described_class.new('7d').parse
        expect(result).to be_within(1.second).of(7.days.ago)
      end

      it 'parses weeks ago (2w)' do
        result = described_class.new('2w').parse
        expect(result).to be_within(1.second).of(2.weeks.ago)
      end

      it 'parses months ago (3m)' do
        result = described_class.new('3m').parse
        expect(result).to be_within(1.second).of(90.days.ago)
      end

      it 'parses years ago (1y)' do
        result = described_class.new('1y').parse
        expect(result).to be_within(1.second).of(365.days.ago)
      end

      it 'is case insensitive for relative dates' do
        expect(described_class.new('TODAY').parse).to eq(described_class.new('today').parse)
        expect(described_class.new('7D').parse).to be_within(1.second).of(described_class.new('7d').parse)
      end
    end

    context 'with invalid dates' do
      it 'returns nil for blank value' do
        expect(described_class.new('').parse).to be_nil
        expect(described_class.new('  ').parse).to be_nil
        expect(described_class.new(nil).parse).to be_nil
      end

      it 'returns nil for invalid format' do
        expect(described_class.new('notadate').parse).to be_nil
        expect(described_class.new('2024-13-01').parse).to be_nil
        expect(described_class.new('invalid').parse).to be_nil
      end
    end
  end

  describe '#valid?' do
    it 'returns true for valid dates' do
      expect(described_class.new('2024-01-15').valid?).to be true
      expect(described_class.new('today').valid?).to be true
      expect(described_class.new('7d').valid?).to be true
    end

    it 'returns false for invalid dates' do
      expect(described_class.new('').valid?).to be false
      expect(described_class.new('notadate').valid?).to be false
    end
  end
end
