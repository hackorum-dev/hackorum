# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AdvisoryLock, type: :service do
  it 'yields when lock is acquired' do
    result = described_class.with_lock('test-lock') { 42 }
    expect(result).to eq(42)
  end
end
