# frozen_string_literal: true

require 'strscan'

class JsonPath
  module RFC9535
    # Recursive-descent parser for the RFC 9535 grammar.
    #
    # A single parser instance drives both the outer query and the embedded
    # filter expressions. The bracket depth counter lets a filter expression
    # locate the closing bracket that terminates it even when it contains
    # nested queries, groups and function calls.
    class Parser
      INTEGER_RANGE = (-(2**53 - 1)..(2**53 - 1)).freeze
      NAME_START = /[A-Za-z_\u0080-\u{10FFFF}]/
      NAME_CHAR = /[A-Za-z0-9_\u0080-\u{10FFFF}\-]/
      KEYWORD_BOUNDARY = /(?![A-Za-z0-9_])/
      NUMBER = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/

      def self.parse(query)
        new(query).parse_query
      end

      def initialize(query)
        raise ParseError, 'query must be a string' unless query.is_a?(String)

        @s = StringScanner.new(query)
        @depth = 0
        @in_filter = false
        @stop_depth = 0
        @value_position = false
      end

      # json-path-query = root-identifier *segment
      def parse_query
        consume(/\$/, "query must start with '$'")
        segments = parse_segments
        error('unexpected trailing characters') unless @s.eos?
        segments
      end

      private

      def parse_segments
        segments = []
        loop do
          break if segment_terminated?
          if @s.scan(/\.\./)
            segments << parse_descendant_segment
          elsif @s.scan(/\./)
            if @s.scan(/\*/)
              segments << Segment.new(:child, [:wildcard])
            else
              segments << Segment.new(:child, [[:name, parse_dot_name]])
            end
          elsif open_bracket?
            @s.getch
            @depth += 1
            segments << Segment.new(:child, parse_bracket_segment)
          else
            break
          end
        end
        segments
      end

      # Inside a filter, a closing bracket at the filter's depth terminates
      # the embedded query rather than opening another bracket segment.
      def segment_terminated?
        @in_filter && @depth == @stop_depth && @s.match?(/[\],]/)
      end

      def open_bracket?
        # An opening bracket always opens a new bracket segment; the closing
        # bracket at the filter's stop depth terminates that filter.
        @s.match?(/\[/)
      end

      def parse_descendant_segment
        if open_bracket?
          @s.getch
          @depth += 1
          Segment.new(:descendant, parse_bracket_segment)
        elsif @s.scan(/\*/)
          Segment.new(:descendant, [:wildcard])
        else
          Segment.new(:descendant, [[:name, parse_dot_name]])
        end
      end

      def parse_dot_name
        token = @s.scan(/#{NAME_START}#{NAME_CHAR}*/)
        error('expected a member name') unless token
        token
      end

      # bracketed-selection = "[" S selector *(S "," S selector) S "]"
      def parse_bracket_segment
        skip_ws
        if @s.scan(/\?/)
          return [[:filter, parse_filter_segment]]
        end

        selectors = []
        loop do
          selectors << parse_bracket_selector
          skip_ws
          if @s.scan(/\]/)
            @depth -= 1
            break
          end
          consume(/,/, "expected ',' or ']' inside bracket segment")
          skip_ws
        end
        selectors
      end

      # The opening bracket of this segment was already consumed and counted
      # by the caller. Parse the filter and consume this segment's bracket.
      def parse_filter_segment
        expression = parse_filter_expression
        skip_ws
        consume(/\]/, "expected ']' to close filter selector")
        @depth -= 1
        expression
      end

      def parse_bracket_selector
        if @s.scan(/\*/)
          :wildcard
        elsif @s.match?(/['"]/)
          [:name, scan_string_literal]
        else
          parse_index_or_slice
        end
      end

      def parse_index_or_slice
        if @s.scan(/:/)
          skip_ws
          return parse_slice(nil)
        end

        start = scan_index_integer
        skip_ws
        return [:index, start] unless @s.scan(/:/)

        skip_ws
        parse_slice(start)
      end

      def parse_slice(start)
        skip_ws
        stop = @s.match?(/[:\]\,]/) ? nil : scan_index_integer
        skip_ws
        step = 1
        if @s.scan(/:/)
          skip_ws
          step = scan_index_integer
          error('slice step must not be zero') if step.zero?
        end
        [:slice, start, stop, step]
      end

      def scan_index_integer
        token = @s.scan(/-?(?:0|[1-9]\d*)/)
        error('expected an integer index or slice bound') unless token
        value = Integer(token)
        error('integer index is out of range') unless INTEGER_RANGE.include?(value)
        value
      end

      # -----------------------------------------------------------------
      # Filter expressions
      # -----------------------------------------------------------------

      def parse_filter_expression
        was_in_filter = @in_filter
        was_stop_depth = @stop_depth
        @in_filter = true
        @stop_depth = @depth
        skip_ws
        node = parse_or_expression
        skip_ws
        node
      ensure
        @in_filter = was_in_filter
        @stop_depth = was_stop_depth
      end

      def parse_or_expression
        left = parse_and_expression
        loop do
          skip_ws
          break unless @s.scan(/\|\|/)

          skip_ws
          left = [:or, left, parse_and_expression]
        end
        left
      end

      def parse_and_expression
        left = parse_basic_expression
        loop do
          skip_ws
          break unless @s.scan(/&&/)

          skip_ws
          left = [:and, left, parse_basic_expression]
        end
        left
      end

      def parse_basic_expression
        if @s.scan(/!/)
          return [:not, parse_basic_expression]
        end
        if @s.scan(/\(/)
          skip_ws
          inner = parse_or_expression
          skip_ws
          consume(/\)/, "expected ')'")
          return [:group, inner]
        end

        atom = parse_atom
        skip_ws
        operator = @s.scan(/==|!=|<=|>=|[<>]/)
        if operator.nil?
          unless @value_position
            error('a bare literal is not a valid filter expression') if atom[0] == :lit
            if atom[0] == :func && Type.of(atom) == Type::VALUE
              error('a value function cannot be used as a logical test')
            end
          end
          return atom
        end

        skip_ws
        [:cmp, operator, atom, parse_comparable(operator)]
      end

      def parse_comparable(operator)
        node = if @s.match?(/['"]/)
                 [:lit, scan_string_literal]
               elsif @s.match?(/true|false|null#{KEYWORD_BOUNDARY}/)
                 parse_keyword_literal
               elsif @s.match?(/#{NUMBER}/)
                 [:lit, scan_number]
               elsif @s.match?(/[a-z][a-z0-9_]*(?=\()/)
                 parse_function
               elsif @s.match?(/[$@]/)
                 parse_filter_query
               else
                 error('expected a comparable value')
               end
        validate_comparable(node, operator)
        node
      end

      def validate_comparable(node, operator)
        if node[0] == :query && !node[3]
          error('only a singular query can be compared')
        end
        if node[0] == :func && Type.of(node) != Type::VALUE
          error('only a value returning function can be compared')
        end
        return unless %w[< > <= >=].include?(operator)

        if node[0] == :lit && !node[1].is_a?(Numeric) && !node[1].is_a?(String)
          error('ordering comparisons require numbers or strings')
        end
      end

      def parse_keyword_literal
        token = @s.scan(/true|false|null#{KEYWORD_BOUNDARY}/)
        [:lit, token == 'null' ? nil : token == 'true']
      end

      def parse_atom
        if @s.match?(/[a-z][a-z0-9_]*(?=\()/)
          parse_function
        elsif @s.match?(/[$@]/)
          parse_filter_query
        elsif @s.match?(/['"]/)
          [:lit, scan_string_literal]
        elsif @s.match?(/true|false|null#{KEYWORD_BOUNDARY}/)
          parse_keyword_literal
        elsif @s.match?(/#{NUMBER}/)
          [:lit, scan_number]
        else
          error('unexpected token in filter expression')
        end
      end

      # filter-query = rel-query / json-path-query
      def parse_filter_query
        root = consume(/[$@]/, "expected '$' or '@'")
        segments = parse_segments
        singular = segments.all? do |segment|
          segment.kind == :child && segment.selectors.size == 1 &&
            %i[name index].include?(segment.selectors[0][0])
        end
        [:query, root, segments, singular]
      end

      def parse_function
        name = @s.scan(/[a-z][a-z0-9_]*/)
        signature = FUNCTIONS[name]
        error("unknown function '#{name}'") unless signature
        consume(/\(/, "expected '(' after function name")
        skip_ws
        args = @s.match?(/\)/) ? [] : parse_function_arguments(signature[:args])
        consume(/\)/, "expected ')' to close function '#{name}'")
        check_function_arguments(name, signature, args)
        [:func, name, args]
      end

      def parse_function_arguments(declared_types)
        args = []
        loop do
          args << parse_function_argument(declared_types[args.size])
          skip_ws
          break unless @s.scan(/,/)
          skip_ws
        end
        args
      end

      # A RegexType argument is a bare string literal; all other arguments are
      # full logical-OR expressions. Parsing literals directly also keeps
      # parentheses and operators inside strings atomic.
      def parse_function_argument(declared)
        if declared == :regexp
          error('expected a string literal I-Regexp argument') unless @s.match?(/['"]/)
          [:lit, scan_string_literal]
        else
          previous = @value_position
          @value_position = true
          begin
            parse_or_expression
          ensure
            @value_position = previous
          end
        end
      end

      def check_function_arguments(name, signature, args)
        if args.size != signature[:args].size
          error("function '#{name}' expects #{signature[:args].size} argument(s)")
        end
        args.zip(signature[:args]).each do |arg, declared|
          next if argument_matches?(name, arg, declared)

          error("function '#{name}' expects a #{declared} argument but got #{Type.of(arg)}")
        end
      end

      def argument_matches?(name, arg, declared)
        case declared
        when :nodes
          Type.of(arg) == Type::NODES
        when :value
          Type.of(arg) == Type::VALUE
        when :logical
          Type.of(arg) == Type::LOGICAL
        when :regexp
          validate_regexp_argument(name, arg)
        else
          false
        end
      end

      def validate_regexp_argument(name, arg)
        return false unless arg[0] == :lit && arg[1].is_a?(String)

        Evaluator.compile_iregexp(arg[1], false)
        true
      rescue RegexpError
        error("function '#{name}' received an invalid I-Regexp")
      end

      def scan_number
        token = @s.scan(/#{NUMBER}/)
        error('expected a number') unless token
        if token.include?('.') || token =~ /[eE]/
          Float(token)
        else
          Integer(token)
        end
      end

      # String literals are tokenized whole, so parentheses and logical
      # operators inside them never affect expression parsing.
      def scan_string_literal
        quote = @s.getch
        value = +''
        loop do
          chunk = @s.scan(/[^#{quote}\\]+/)
          value << chunk if chunk
          if @s.scan(/\\/)
            value << scan_escape
          elsif @s.scan(/#{quote}/)
            return value
          else
            error('unterminated string literal')
          end
        end
      end

      def scan_escape
        escaped = @s.getch
        case escaped
        when 'b' then "\b"
        when 'f' then "\f"
        when 'n' then "\n"
        when 'r' then "\r"
        when 't' then "\t"
        when 'u' then scan_unicode_escape
        when nil then error('unterminated escape sequence')
        else escaped
        end
      end

      def scan_unicode_escape
        hex = @s.scan(/[0-9a-fA-F]{4}/) || error('invalid unicode escape')
        code = hex.to_i(16)
        if (0xD800..0xDBFF).include?(code) && @s.scan(/\\u([0-9a-fA-F]{4})/)
          low = @s[1].to_i(16)
          code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00) if (0xDC00..0xDFFF).include?(low)
        end
        [code].pack('U')
      end

      def skip_ws
        @s.scan(/[ \t\n\r]*/)
      end

      def consume(pattern, message)
        @s.scan(pattern) || error(message)
      end

      def error(message)
        raise ParseError, "#{message} (at position #{@s.pos} in '#{@s.string}')"
      end
    end
  end
end
