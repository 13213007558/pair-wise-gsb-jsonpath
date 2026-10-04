# frozen_string_literal: true

class JsonPath
  module RFC9535
    # Raised when a query or filter expression violates the RFC 9535 grammar
    # or is not well-typed according to the declared function signatures.
    class ParseError < ArgumentError; end

    # A single node selected from the argument value. The path is its RFC 9535
    # Normalized Path (Section 2.7).
    Result = Struct.new(:value, :normalized_path) do
      alias path normalized_path
    end

    # Segment kinds: :child or :descendant. Selectors are:
    #   :wildcard
    #   [:name, String]
    #   [:index, Integer]
    #   [:slice, Integer|nil, Integer|nil, Integer]
    #   [:filter, ast]
    Segment = Struct.new(:kind, :selectors)

    # Declared argument and result types for the RFC 9535 built-in functions.
    FUNCTIONS = {
      'length' => { :args => [:value], :return => :value },
      'count' => { :args => [:nodes], :return => :value },
      'value' => { :args => [:nodes], :return => :value },
      'match' => { :args => [:value, :regexp], :return => :logical },
      'search' => { :args => [:value, :regexp], :return => :logical }
    }.freeze

    # Static classification of a filter expression AST node, used to enforce
    # the NodesType / ValueType / LogicalType argument declarations.
    module Type
      NODES = :nodes
      VALUE = :value
      LOGICAL = :logical

      def self.of(node)
        case node[0]
        when :lit then VALUE
        when :query then node[3] ? VALUE : NODES
        when :func then FUNCTIONS.fetch(node[1])[:return] == LOGICAL ? LOGICAL : VALUE
        when :group then of(node[1])
        else LOGICAL # :cmp and :not
        end
      end
    end
  end
end
