# frozen_string_literal: true

class JsonPath
  module RFC9535
    # Evaluates parsed RFC 9535 queries against a Ruby value produced from
    # JSON (Hash, Array, String, Integer, Float, true, false, nil).
    #
    # Nothing (the absence of a value) is represented by the NOTHING sentinel
    # so it never conflates with JSON null, false or an empty string.
    class Evaluator
      NOTHING = Object.new.tap { |obj| def obj.to_s; 'Nothing'; end }.freeze

      def self.compile_iregexp(pattern, search)
        flags = Regexp::FIXEDENCODING
        source = translate_iregexp(pattern)
        Regexp.new(search ? "\\A(?:.*#{source}.*)\\z" : "\\A#{source}\\z", flags)
      end

      # I-Regexp (RFC 8610) is ECMAScript-like without the 'g' flag. Ruby
      # regular expressions cover the common subset; only the case-insensitive
      # inline flag is meaningful here.
      def self.translate_iregexp(pattern)
        source = pattern.gsub('\\/', '/')
        if source =~ /\\A\(\?([im]*)(?:-[im]*)?\)(.*)\\z/m
          flags = Regexp.last_match(1)
          source = Regexp.last_match(2)
          source = "(?#{flags})#{source}" unless flags.empty?
        end
        source
      end

      def self.query(root, segments)
        new(root).query(segments)
      end

      def initialize(root)
        @root = root
      end

      # Returns an ordered array of [value, normalized_path] pairs. Duplicate
      # nodes are never removed: a node reached more than once is yielded more
      # than once, exactly as required by RFC 9535.
      def query(segments)
        nodes = [[@root, '$']]
        segments.each { |segment| nodes = apply_segment(nodes, segment) }
        nodes
      end

      private

      def apply_segment(nodes, segment)
        nodes.flat_map do |value, path|
          if segment.kind == :descendant
            apply_descendant(value, path, segment.selectors)
          else
            apply_selectors(value, path, segment.selectors)
          end
        end
      end

      # Descendant segments visit in document order (depth first), selecting
      # at each visited node and then continuing into its children.
      def apply_descendant(value, path, selectors)
        results = apply_selectors(value, path, selectors)
        case value
        when Array
          value.each_with_index do |child, index|
            results.concat(apply_descendant(child, append_index(path, index), selectors))
          end
        when Hash
          value.each do |key, child|
            results.concat(apply_descendant(child, append_member(path, key), selectors))
          end
        end
        results
      end

      # Multiple selectors in one child segment must not select one node more
      # than once. Identities are local to each input value.
      def apply_selectors(value, path, selectors)
        seen = {}
        selectors.flat_map do |selector|
          apply_selector(value, path, selector).reject do |_child, identity|
            identity && seen[identity]
          end.each do |_child, identity|
            seen[identity] = true if identity
          end.map { |child, _identity| child }
        end
      end

      def apply_selector(value, path, selector)
        return select_children(value, path) if selector == :wildcard

        case selector[0]
        when :name
          select_name(value, path, selector[1])
        when :index
          select_index(value, path, selector[1])
        when :slice
          select_slice(value, path, selector[1], selector[2], selector[3])
        when :filter
          select_filter(value, path, selector[1])
        end
      end

      def select_children(value, path)
        case value
        when Hash
          value.map { |key, child| [[child, append_member(path, key)], nil] }
        when Array
          value.each_with_index.map { |child, index| [[child, append_index(path, index)], nil] }
        else
          []
        end
      end

      def select_name(value, path, name)
        return [] unless value.is_a?(Hash) && value.key?(name)

        [[[value[name], append_member(path, name)], key_identity(value, name)]]
      end

      def select_index(value, path, index)
        return [] unless value.is_a?(Array)

        normalized = index < 0 ? index + value.size : index
        return [] unless normalized >= 0 && normalized < value.size

        [[[value[normalized], append_index(path, normalized)], index_identity(value, normalized)]]
      end

      def select_slice(value, path, start, stop, step)
        return [] unless value.is_a?(Array)

        slice_indices(value.size, start, stop, step).map do |index|
          [[value[index], append_index(path, index)], index_identity(value, index)]
        end
      end

      # Canonical slice algorithm from RFC 9535, section 2.3.4.
      def slice_indices(length, start, stop, step)
        positive = step.positive?
        n_start = start.nil? ? (positive ? 0 : length - 1) : normalize_slice_bound(start, length, positive)
        n_stop = stop.nil? ? (positive ? length : -1) : normalize_slice_bound(stop, length, positive)

        if step.positive?
          return [] if n_start >= n_stop

          first = [n_start, 0].max
          last = [n_stop - 1, length - 1].min
          return [] if first > last
        else
          return [] if n_start <= n_stop
        end

        indices = []
        index = step.positive? ? first : n_start
        limit = step.positive? ? last : n_stop
        while step.positive? ? index <= limit : index > limit
          indices << index
          index += step
        end
        indices
      end

      def normalize_slice_bound(bound, length, positive)
        if bound >= length
          length
        elsif bound < -length
          positive ? -1 : length
        elsif bound < 0
          bound + length
        else
          bound
        end
      end

      def select_filter(value, path, expression)
        case value
        when Array
          memo = []
          value.each_with_index do |child, index|
            next unless evaluate_logical(expression, child, @root) == true

            memo << [[child, append_index(path, index)], index_identity(value, index)]
          end
          memo
        when Hash
          # Filtering an object tests @ against the object itself; when the
          # test passes the whole object is selected (RFC 9535 2.3.5).
          return [[[value, path], nil]] if evaluate_logical(expression, value, @root) == true

          []
        else
          []
        end
      end

      def key_identity(container, key)
        [container.object_id, key]
      end

      def index_identity(container, index)
        [container.object_id, index]
      end

      def append_member(path, key)
        "#{path}[#{normalize_string(key)}]"
      end

      def append_index(path, index)
        "#{path}[#{index}]"
      end

      # RFC 9535 section 2.7: single quoted member names, with the mandatory
      # escapes and JSON-style unicode escapes for other control characters.
      def normalize_string(string)
        escaped = string.gsub(/[\\']/) { |char| "\\#{char}" }
        escaped.gsub(/[\x00-\x1F]/) do |char|
          code = char.ord
          case code
          when 0x08 then '\\b'
          when 0x09 then '\\t'
          when 0x0A then '\\n'
          when 0x0C then '\\f'
          when 0x0D then '\\r'
          else format('\\u%04x', code)
          end
        end.prepend("'").concat("'")
      end

      # ---------------------------------------------------------------
      # Filter evaluation
      # ---------------------------------------------------------------

      def evaluate_logical(node, current, root)
        case node[0]
        when :or
          truthy?(evaluate_logical(node[1], current, root)) ||
            truthy?(evaluate_logical(node[2], current, root))
        when :and
          truthy?(evaluate_logical(node[1], current, root)) &&
            truthy?(evaluate_logical(node[2], current, root))
        when :not
          !truthy?(evaluate_logical(node[1], current, root))
        when :group
          evaluate_logical(node[1], current, root)
        when :cmp
          evaluate_comparison(node, current, root)
        when :query
          evaluate_query_test(node, current, root)
        when :func
          evaluate_function(node, current, root)
        end
      end

      # LogicalType conversion of a filter-query (RFC 9535 2.4.3): a
      # non-singular query is true when its node list is non-empty; a singular
      # query is true only when its one value is neither null nor false.
      def evaluate_query_test(node, current, root)
        nodes = query_nodes(node, current, root)
        return false if nodes.empty?
        return true unless node[3] # singular flag

        value = nodes.first
        !(value.nil? || value == false)
      end

      def truthy?(value)
        value == true
      end

      def evaluate_comparison(node, current, root)
        operator = node[1]
        left = comparable_value(node[2], current, root)
        right = comparable_value(node[3], current, root)
        return false if left == NOTHING || right == NOTHING

        case operator
        when '==' then json_equal?(left, right)
        when '!=' then !json_equal?(left, right)
        when '<' then ordered?(left, right) { |a, b| a < b }
        when '<=' then ordered?(left, right) { |a, b| a <= b }
        when '>' then ordered?(left, right) { |a, b| a > b }
        when '>=' then ordered?(left, right) { |a, b| a >= b }
        end
      end

      def ordered?(left, right)
        return false unless (left.is_a?(Numeric) && right.is_a?(Numeric)) ||
                            (left.is_a?(String) && right.is_a?(String))

        yield(left, right)
      end

      # Equality is only defined between primitives of the same JSON type.
      def json_equal?(left, right)
        return left.nil? && right.nil? if left.nil? || right.nil?
        return left == right if comparable_primitives?(left, right)

        false
      end

      def comparable_primitives?(left, right)
        return true if left.is_a?(Numeric) && right.is_a?(Numeric)
        return true if left.is_a?(String) && right.is_a?(String)

        [true, false].include?(left) && [true, false].include?(right)
      end

      # Comparison operands: literals are values, singular queries yield their
      # one value or Nothing, and value-returning functions yield a value.
      def comparable_value(node, current, root)
        case node[0]
        when :lit then node[1]
        when :query then singular_value(node, current, root)
        when :func then evaluate_function(node, current, root)
        end
      end

      def singular_value(node, current, root)
        nodes = query_nodes(node, current, root)
        nodes.empty? ? NOTHING : nodes.first
      end

      def query_nodes(node, current, root)
        query_root = node[1] == '$' ? root : current
        self.class.new(query_root).query(node[2]).map(&:first)
      end

      def evaluate_function(node, current, root)
        name = node[1]
        args = node[2].map { |arg| evaluate_argument(arg, current, root) }
        case name
        when 'length' then function_length(args[0])
        when 'count' then args[0].size
        when 'value' then args[0].size == 1 ? args[0].first : NOTHING
        when 'match' then iregexp_match(args[0], args[1], false)
        when 'search' then iregexp_match(args[0], args[1], true)
        end
      end

      # Function arguments are coerced according to their declared type.
      # NodesType arguments stay node lists; ValueType arguments become a
      # single value or Nothing; LogicalType arguments become true/false.
      def evaluate_argument(arg, current, root)
        case Type.of(arg)
        when Type::NODES
          query_nodes(arg, current, root)
        when Type::VALUE
          comparable_value(arg, current, root)
        when Type::LOGICAL
          truthy?(evaluate_logical(arg, current, root))
        end
      end

      def function_length(value)
        case value
        when String then value.length
        when Hash then value.size
        when Array then value.size
        else NOTHING
        end
      end

      def iregexp_match(value, pattern, search)
        return false unless value.is_a?(String)

        regexp = self.class.compile_iregexp(pattern, search)
        !!(regexp.match?(value))
      rescue RegexpError
        false
      end
    end
  end
end
