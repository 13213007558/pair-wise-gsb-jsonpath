# frozen_string_literal: true

require 'multi_json'
require 'jsonpath/rfc9535/parser'
require 'jsonpath/rfc9535/evaluator'

class JsonPath
  module RFC9535
    # Query is an independent RFC 9535 JSONPath query. It is completely
    # separate from JsonPath's legacy Goessner mode.
    class Query
      attr_reader :expression, :ast

      def self.on(object_or_string, expression)
        new(expression).on(object_or_string)
      end

      def initialize(expression)
        @expression = expression
        @ast = Parser.parse(expression)
      end

      # Returns [value, normalized_path] pairs. Repeated selections of the
      # same node are preserved (RFC 9535 child segments do not de-duplicate).
      def result(object_or_string = nil)
        object = parse_object(object_or_string)
        Evaluator.result(@ast, object)
               .map { |node| [node.value, node.path] }
      end
      alias to_a result

      # Returns only the selected values.
      def values(object_or_string = nil)
        result(object_or_string).map(&:first)
      end
      alias on values

      # Returns only the Normalized Paths (RFC 9535 section 2.7).
      def paths(object_or_string = nil)
        result(object_or_string).map(&:last)
      end

      def each(object_or_string = nil)
        return enum_for(:each, object_or_string) unless block_given?

        result(object_or_string).each { |pair| yield(*pair) }
        self
      end

      def first(object_or_string = nil)
        result(object_or_string).first
      end

      def result_with_options(object_or_string, opts = {})
        pairs = result(object_or_string)
        return pairs.map(&:last) if opts[:paths]
        return pairs unless opts[:symbolize_keys]

        pairs.map do |value, path|
          next [value, path] unless value.is_a?(Hash)

          [value.each_with_object({}) { |(k, v), memo| memo[k.to_sym] = v }, path]
        end
      end

      private

      def parse_object(object_or_string)
        return object_or_string unless object_or_string.is_a?(String)

        MultiJson.respond_to?(:parse) ? MultiJson.parse(object_or_string) : MultiJson.decode(object_or_string)
      end
    end
  end
end
