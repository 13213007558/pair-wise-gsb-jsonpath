# frozen_string_literal: true

class JsonPath
  module RFC9535
    # Evaluator walks an AST against a JSON value and produces nodes together
    # with their Normalized Paths (RFC 9535 section 2.7).
    class Evaluator
      Node = Struct.new(:value, :path)

      def self.result(ast, object)
        new(object).ast_result(ast, object)
      end

      def initialize(root)
        @root = root
      end

      def ast_result(ast, object)
        walk(ast[1..], Node.new(object, '$'), [Node.new(object, '$')])
      end

      private

      def walk(segments, root, nodes)
        segments.each_with_object(nodes) do |segment, memo|
          memo.replace(apply_segment(segment, memo))
        end
      end

      def apply_segment(segment, nodes)
        if segment.is_a?(DescSeg)
          nodes.flat_map { |node| apply_descendant(segment.selectors, node) }
        else
          nodes.flat_map { |node| apply_selectors(segment.selectors, node) }
        end
      end

      def apply_descendant(selectors, node)
        selected = visit(node).flat_map { |visited| apply_selectors(selectors, visited) }
        dedupe(selected)
      end

      def visit(node)
        case node.value
        when Hash, Array
          [node].concat(children_of(node).flat_map { |child| visit(child) })
        else
          [node]
        end
      end

      def children_of(node)
        case node.value
        when Hash
          node.value.keys.map do |key|
            Node.new(node.value[key], "#{node.path}[#{normalize_name(key)}]")
          end
        when Array
          node.value.each_index.map do |index|
            Node.new(node.value[index], "#{node.path}[#{index}]")
          end
        else
          []
        end
      end

      # A descendant segment selects at most one node per path (RFC 9535
      # section 2.3.2), while a child segment with multiple selectors keeps
      # every selection, including duplicates.
      def dedupe(nodes)
        seen = {}
        nodes.each_with_object([]) do |node, memo|
          next if seen.key?(node.path)

          seen[node.path] = true
          memo << node
        end
      end

      def apply_selectors(selectors, node)
        selectors.flat_map { |selector| apply_selector(selector, node) }
      end

      def apply_selector(selector, node)
        case selector
        when NameSel then apply_name(selector, node)
        when WildcardSel then children_of(node)
        when IndexSel then apply_index(selector, node)
        when SliceSel then apply_slice(selector, node)
        when FilterSel then apply_filter(selector, node)
        else raise ParseError, 'unsupported selector'
        end
      end

      def apply_name(selector, node)
        return [] unless node.value.is_a?(Hash) && node.value.key?(selector.name)

        [Node.new(node.value[selector.name], "#{node.path}[#{normalize_name(selector.name)}]")]
      end

      def apply_index(selector, node)
        return [] unless node.value.is_a?(Array)

        index = selector.index
        index += node.value.length if index.negative?
        return [] if index.negative? || index >= node.value.length

        [Node.new(node.value[index], "#{node.path}[#{index}]")]
      end

      def apply_slice(selector, node)
        return [] unless node.value.is_a?(Array)

        slice_indices(selector, node.value.length).map do |index|
          Node.new(node.value[index], "#{node.path}[#{index}]")
        end
      end

      def slice_indices(selector, length)
        step = selector.step
        if step.positive?
          lower = bound(selector.start, length, 0) || 0
          upper = selector.stop.nil? ? length : bound(selector.stop, length, length)
          lower = [[lower, 0].max, length].min
          upper = [[upper, 0].max, length].min
          indices_from(lower, upper, step) { |i| i < upper }
        else
          lower = bound(selector.start, length, length - 1) || length - 1
          upper = selector.stop.nil? ? -1 : bound(selector.stop, length, -1)
          lower = [[lower, -1].max, length - 1].min
          upper = [[upper, -1].max, length - 1].min
          indices_from(lower, upper, step) { |i| i > upper }
        end
      end

      def bound(value, length, default)
        return default if value.nil?

        value += length if value.negative?
        value
      end

      def indices_from(start, _stop, step)
        indices = []
        index = start
        while yield(index)
          indices << index
          index += step
        end
        indices
      end

      def apply_filter(selector, node)
        case node.value
        when Array
          node.value.each_index.each_with_object([]) do |index, memo|
            child = Node.new(node.value[index], "#{node.path}[#{index}]")
            memo << child if truthy?(eval_logical(selector.expression, child))
          end
        else
          truthy?(eval_logical(selector.expression, node)) ? [node] : []
        end
      end

      def eval_logical(expression, current)
        case expression
        when QueryTest
          if expression.query.is_a?(Func)
            truthy?(eval_function(expression.query, current))
          else
            query_nodes(expression.query, current).any?
          end
        when ParenExpr
          eval_logical(expression.expression, current)
        when NotExpr
          value = eval_logical(expression.expression, current)
          value == Nothing ? Nothing : !value
        when BinaryExpr
          eval_binary(expression, current)
        when Func
          eval_function(expression, current)
        else
          raise ParseError, 'invalid filter expression'
        end
      end

      def eval_binary(expression, current)
        case expression.operator
        when :and
          left = eval_logical(expression.left, current)
          return false unless truthy?(left)

          truthy?(eval_logical(expression.right, current))
        when :or
          left = eval_logical(expression.left, current)
          return true if truthy?(left)
          right = eval_logical(expression.right, current)
          return true if truthy?(right)
          return Nothing if left == Nothing && right == Nothing

          false
        else
          left = eval_comparable(expression.left, current)
          right = eval_comparable(expression.right, current)
          compare(expression.operator, left, right)
        end
      end

      def truthy?(value)
        value == true
      end

      def eval_comparable(node, current)
        case node
        when Literal then node.value
        when Array then singular_value(node, current)
        when Func then eval_function(node, current)
        else raise ParseError, 'invalid comparison'
        end
      end

      def singular_value(query, current)
        nodes = query_nodes(query, current)
        return Nothing if nodes.empty?

        nodes.first.value
      end

      def query_nodes(query, current)
        head = query.first
        start = head.is_a?(CurrentNode) ? current : root_node
        walk(query[1..], root_node, [start])
      end

      def root_node
        Node.new(@root, '$')
      end

      def compare(operator, left, right)
        case operator
        when :== then equality(left, right)
        when :!= then !equality(left, right)
        else ordered(operator, left, right)
        end
      end

      def equality(left, right)
        return false if left == Nothing || right == Nothing

        left == right
      end

      def ordered(operator, left, right)
        return false if left == Nothing || right == Nothing
        return false unless (left.is_a?(Numeric) && right.is_a?(Numeric)) ||
                            (left.is_a?(String) && right.is_a?(String))

        left.public_send(operator, right)
      end

      def eval_function(function, current)
        args = function.args.map { |arg| eval_argument(function.name, arg, current) }
        case function.name
        when 'count' then args.first.length
        when 'value' then args.first
        when 'length' then length_of(args.first)
        when 'match' then match_function(args)
        when 'search'
          value, regexp = args
          value.is_a?(String) && regexp.match?(value)
        end
      end

      def eval_argument(name, arg, current)
        case arg
        when Literal then arg.value
        when Array then evaluate_query_argument(name, arg, current)
        when Func then eval_function(arg, current)
        else eval_logical(arg, current)
        end
      end

      def evaluate_query_argument(name, query, current)
        case name
        when 'value', 'match', 'search'
          singular_value(query, current)
        when 'length'
          nodes = query_nodes(query, current)
          nodes.length == 1 ? nodes.first.value : Nothing
        else
          query_nodes(query, current).map(&:value)
        end
      end

      def match_function(args)
        value, regexp = args
        return false unless value.is_a?(String)

        Regexp.new('\\A(?:' + regexp.source + ')\\z').match?(value)
      end

      def length_of(value)
        case value
        when Hash, Array, String then value.length
        else Nothing
        end
      end

      def normalize_name(name)
        escaped = name.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }
        escaped = escaped.gsub("\b", '\\b')
                         .gsub("\f", '\\f')
                         .gsub("\n", '\\n')
                         .gsub("\r", '\\r')
                         .gsub("\t", '\\t')
        "'#{escaped}'"
      end
    end
  end
end
