module Lineage
  module Processor
    # no Mutex: set! runs from trap handlers, where locking raises
    class StopFlag
      def initialize = @set = false
      def set! = @set = true
      def set? = @set
    end
  end
end
