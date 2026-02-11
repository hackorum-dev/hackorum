# frozen_string_literal: true

require "digest/sha1"

class AdvisoryLock
  # Acquire a PostgreSQL advisory lock for the duration of the block.
  # Returns the block's return value if the lock is acquired, or nil if not.
  def self.with_lock(key, wait: false)
    a, b = hash_to_two_ints(key)
    acquired = try_lock(a, b, wait: wait)
    return nil unless acquired
    begin
      yield
    ensure
      unlock(a, b)
    end
  end

  def self.try_lock(a, b, wait: false)
    query = wait ? "SELECT pg_advisory_lock(?, ?)" : "SELECT pg_try_advisory_lock(?, ?)"
    sql = ActiveRecord::Base.send(:sanitize_sql_array, [ query, a, b ])
    if wait
      ActiveRecord::Base.connection.execute(sql)
      true
    else
      result = ActiveRecord::Base.connection.select_value(sql)
      [ true, "t", 1, "1" ].include?(result)
    end
  end

  def self.unlock(a, b)
    sql = ActiveRecord::Base.send(:sanitize_sql_array, [ "SELECT pg_advisory_unlock(?, ?)", a, b ])
    ActiveRecord::Base.connection.execute(sql)
  end

  def self.hash_to_two_ints(key)
    digest = Digest::SHA1.digest(key.to_s)
    a = digest[0, 4].unpack1("l>") # 32-bit signed big-endian
    b = digest[4, 4].unpack1("l>")
    [ a, b ]
  end
  private_class_method :hash_to_two_ints
end
