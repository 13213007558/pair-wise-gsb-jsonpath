# frozen_string_literal: true

class JsonPath
  module RFC9535
    # Minimal Enumerable adapter so an RFC 9535 query responds to the same
    # iteration based helpers (first, to_a, any?, ...) as the legacy mode.
    class Enumerable
      include ::Enumerable

      def initialize(segments, object)
        @segments = segments
        @object = object
      end

      def each
        return to_enum unless block_given?

        Evaluator.query(@object, @segments).each do |value, _path|
          yield value
        end
      end

      # Yields Result objects carrying the value and its Normalized Path.
      def each_result
        return enum_for(:each_result) unless block_given?

        Evaluator.query(@object, @segments).each do |value, path|
          yield Result.new(value, path)
        end
      end

      def results
        each_result.to_a
      end

      def paths
        Evaluator.query(@object, @segments).map { |_value, path| path }
      end
    end
  end
end
