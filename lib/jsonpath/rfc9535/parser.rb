# frozen_string_literal: true

require 'strscan'

class JsonPath
  module RFC9535
    # ParseError is raised when an expression does not conform to RFC 9535.
    class ParseError < ArgumentError; end

    # NothingClass represents the distinguished value returned by singular
    # queries and some functions when no value exists. It is intentionally
    # different from JSON null (nil), true and false.
    class NothingClass
      def inspect
        'Nothing'
      end
      alias to_s inspect
    end
    Nothing = NothingClass.new.freeze

    RootNode = Struct.new(:kind)
    CurrentNode = Struct.new(:kind)
    ChildSeg = Struct.new(:selectors, :singular)
    DescSeg = Struct.new(:selectors)
    NameSel = Struct.new(:name)
    WildcardSel = Struct.new(:_)
    IndexSel = Struct.new(:index)
    SliceSel = Struct.new(:start, :stop, :step)
    FilterSel = Struct.new(:expression)
    Literal = Struct.new(:value)
    Func = Struct.new(:name, :args, :return_type)
    NotExpr = Struct.new(:expression)
    BinaryExpr = Struct.new(:operator, :left, :right)
    ParenExpr = Struct.new(:expression)
    QueryTest = Struct.new(:query)

    # Parser turns an RFC 9535 query or filter expression into an AST.
    class Parser
      COMPARISONS = %w[== != <= >= < >].freeze
      FUNCTIONS = {
        'count' => { :args => [:nodes], :return => :value },
        'value' => { :args => [:singular], :return => :value },
        'length' => { :args => [:any], :return => :value },
        'match' => { :args => %i[value string], :return => :logical },
        'search' => { :args => %i[value string], :return => :logical }
      }.freeze

      def self.parse(expression)
        parser = new(expression)
        query = parser.send(:parse_root_query)
        parser.send(:finish, 'query')
        query
      end

      def self.parse_filter(expression)
        parser = new(expression)
        ast = parser.send(:parse_or)
        parser.send(:finish, 'filter expression')
        ast
      end

      private

      def initialize(expression)
        @scanner = StringScanner.new(expression)
      end

      def parse_root_query
        query = parse_query
        raise ParseError, 'query must start with $' unless query.first.is_a?(RootNode)

        query
      end

      def parse_or
        left = parse_and
        ws
        while skip(/\|\|/)
          right = parse_and
          left = BinaryExpr.new(:or, left, right)
          ws
        end
        left
      end

      def parse_and
        left = parse_basic
        ws
        while skip(/&&/)
          right = parse_basic
          left = BinaryExpr.new(:and, left, right)
          ws
        end
        left
      end

      def parse_basic
        ws
        if skip(/!/)
          ws
          atom = parse_atom
          atom = QueryTest.new(atom) if atom.is_a?(Array)
          NotExpr.new(atom)
        elsif skip(/\(/)
          expression = parse_or
          ws
          expect(')')
          ParenExpr.new(expression)
        else
          parse_test_or_comparison
        end
      end

      def parse_test_or_comparison
        left = parse_atom
        lookahead = @scanner.rest.sub(/\A[ \t\n\r]+/, '')
        operator = COMPARISONS.sort_by(&:length).reverse.find { |c| lookahead.start_with?(c) }
        unless operator
          ensure_test(left)
          return QueryTest.new(left)
        end
        ws
        unless skip(Regexp.new(Regexp.escape(operator)))
          raise ParseError, "expected '#{operator}'"
        end
        ws
        right = parse_comparable
        ensure_comparable(left)
        ensure_comparable(right)
        BinaryExpr.new(operator.to_sym, left, right)
      end

      def ensure_test(node)
        return unless node.is_a?(Func) && node.return_type != :logical

        raise ParseError, "function '#{node.name}' cannot be used as a test"
      end

      def ensure_comparable(node)
        case node
        when Literal then nil
        when Array then ensure_singular(node, 'comparison')
        when Func
          raise ParseError, "function '#{node.name}' result is not a value" unless node.return_type == :value
        else
          raise ParseError, 'expression is not comparable'
        end
      end

      def ensure_singular(nodes, where)
        nodes[1..].each do |segment|
          next if segment.is_a?(ChildSeg) && segment.singular

          raise ParseError, "#{where} requires a singular query"
        end
      end

      def compile_regexp(source)
        Regexp.new("(?:#{source})")
      rescue RegexpError => e
        raise ParseError, "invalid regular expression: #{e.message}"
      end

      def parse_comparable
        if peek_char == '"' || peek_char == "'"
          Literal.new(parse_string)
        elsif number_start?
          parse_number_literal
        elsif literal_word?('true')
          consume_word('true')
          Literal.new(true)
        elsif literal_word?('false')
          consume_word('false')
          Literal.new(false)
        elsif literal_word?('null')
          consume_word('null')
          Literal.new(nil)
        else
          parse_query
        end
      end

      def parse_atom
        if skip(/\(/)
          expression = parse_or
          ws
          expect(')')
          ParenExpr.new(expression)
        elsif function_start?
          parse_function
        else
          parse_query
        end
      end

      def parse_query
        head = case peek_char
               when '$'
                 get
                 RootNode.new(:root)
               when '@'
                 get
                 CurrentNode.new(:current)
               else
                 raise ParseError, "expected '$' or '@' at position #{@scanner.pos}"
               end
        [head].concat(parse_segments)
      end

      def parse_segments
        segments = []
        loop do
          if skip(/\.\./)
            segments << parse_dot_or_bracket_segment(true)
          elsif skip(/\./)
            segments << parse_dot_or_bracket_segment(false)
          elsif peek_char == '['
            segments << parse_bracket_segment(false)
          else
            break
          end
        end
        segments
      end

      def parse_dot_or_bracket_segment(descendant)
        if peek_char == '['
          parse_bracket_segment(descendant)
        elsif peek_char == '*'
          get
          build_segment([WildcardSel.new(nil)], descendant)
        else
          build_segment([NameSel.new(parse_shorthand_name)], descendant)
        end
      end

      def parse_bracket_segment(descendant)
        expect('[')
        selectors = []
        loop do
          ws
          selectors << parse_selector
          ws
          break unless peek_char == ','

          get
        end
        expect(']')
        raise ParseError, 'segment must contain at least one selector' if selectors.empty?

        build_segment(selectors, descendant)
      end

      def parse_selector
        if peek_char == '?'
          get
          ws
          expression = parse_or
          ws
          FilterSel.new(expression)
        elsif peek_char == '*'
          get
          WildcardSel.new(nil)
        elsif peek_char == '"' || peek_char == "'"
          NameSel.new(parse_string)
        elsif function_start?
          parse_function_selector
        elsif slice_here?
          parse_slice
        else
          IndexSel.new(parse_integer)
        end
      end

      def build_segment(selectors, descendant)
        return DescSeg.new(selectors) if descendant

        singular = selectors.one? && (selectors.first.is_a?(NameSel) || selectors.first.is_a?(IndexSel))
        ChildSeg.new(selectors, singular)
      end

      def slice_here?
        saved = @scanner.pos
        @scanner.scan(/-?(?:0|[1-9][0-9]*)?/)
        slice = peek_char == ':'
        @scanner.pos = saved
        slice
      end

      def parse_slice
        start = parse_slice_part
        expect(':')
        stop = parse_slice_part
        step = 1
        if peek_char == ':'
          get
          ws
          step = parse_slice_part || 1
        end
        raise ParseError, 'slice step must not be zero' if step.zero?

        SliceSel.new(start, stop, step)
      end

      def parse_slice_part
        return nil unless number_start?

        parse_integer
      end

      def parse_function_selector
        function = parse_function
        return FilterSel.new(function) if function.return_type == :logical

        raise ParseError, "function '#{function.name}' cannot be used as a selector"
      end

      def parse_function
        name = scan(/[a-z][a-z0-9_]*/) { 'function name' }
        definition = FUNCTIONS.fetch(name) do
          raise ParseError, "unknown function '#{name}'"
        end
        expect('(')
        args = []
        definition[:args].each_with_index do |kind, index|
          ws
          args << parse_function_argument(kind)
          break if index == definition[:args].length - 1

          ws
          expect(',')
        end
        ws
        expect(')')
        Func.new(name, args, definition[:return])
      end

      def parse_function_argument(kind)
        case kind
        when :logical
          argument = parse_or
        when :singular
          argument = parse_query
          ensure_singular(argument, 'value()')
        when :string
          argument = Literal.new(compile_regexp(parse_string))
        when :value
          argument = parse_comparable
        else
          argument = parse_query
        end
        argument
      end

      def parse_shorthand_name
        start = @scanner.pos
        first = peek_char
        raise ParseError, "expected member name at position #{start}" if first.nil? || !NAME_START_RULE.call(first.ord)

        get
        get while !@scanner.eos? && peek_char && NAME_CHAR_RULE.call(peek_char.ord)
        rollback_trailing_spaces(start)
        name = @scanner.string.byteslice(start...@scanner.pos)
        raise ParseError, "expected member name at position #{start}" if name.nil? || name.empty?

        name
      end

      def rollback_trailing_spaces(start)
        scanned = @scanner.string.byteslice(start...@scanner.pos)
        trailing = scanned.bytesize - scanned.rstrip.bytesize
        @scanner.pos -= trailing if trailing.positive? && boundary?(@scanner.rest.lstrip)
      end

      def boundary?(rest)
        rest.empty? ||
          COMPARISONS.any? { |operator| rest.start_with?(operator) } ||
          rest.start_with?('&&', '||', ')', ']', ',', '(', '[', '.')
      end

      def parse_string
        quote = get
        characters = String.new
        until peek_char == quote
          raise ParseError, 'unterminated string literal' if @scanner.eos?

          characters << (peek_char == '\\' ? parse_escape(quote) : get)
        end
        get
        characters
      end

      def parse_escape(quote)
        get
        raise ParseError, 'unterminated escape sequence' if @scanner.eos?

        escaped = get
        case escaped
        when quote then quote
        when '\\' then '\\'
        when '/' then '/'
        when 'b' then "\b"
        when 'f' then "\f"
        when 'n' then "\n"
        when 'r' then "\r"
        when 't' then "\t"
        when 'u' then parse_unicode_escape
        else raise ParseError, "invalid escape sequence '\\#{escaped}'"
        end
      end

      def parse_unicode_escape
        hex = scan(/[0-9A-Fa-f]{4}/) { 'unicode escape' }
        code = hex.to_i(16)
        if (0xD800..0xDBFF).cover?(code)
          expect('\\')
          expect('u')
          low = scan(/[0-9A-Fa-f]{4}/) { 'unicode escape' }.to_i(16)
          raise ParseError, 'invalid unicode surrogate pair' unless (0xDC00..0xDFFF).cover?(low)

          code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
        elsif (0xDC00..0xDFFF).cover?(code)
          raise ParseError, 'invalid unicode surrogate pair'
        end
        [code].pack('U')
      end

      def parse_number_literal
        number = scan(/-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/) { 'number' }
        Literal.new(number =~ /[.eE]/ ? Float(number) : Integer(number))
      end

      def parse_integer
        scan(/-?(?:0|[1-9][0-9]*)/) { 'integer' }.to_i
      end

      def number_start?
        peek?(/-?(?:0|[1-9])/)
      end

      def function_start?
        saved = @scanner.pos
        name = @scanner.scan(/[a-z][a-z0-9_]*(?=\()/)
        @scanner.pos = saved
        name && FUNCTIONS.key?(name)
      end

      def literal_word?(word)
        saved = @scanner.pos
        found = @scanner.scan(/#{word}(?![A-Za-z0-9_])/)
        @scanner.pos = saved
        !found.nil?
      end

      def consume_word(word)
        scan(/#{word}(?![A-Za-z0-9_])/) { word }
      end

      def scan(pattern, what = nil)
        value = @scanner.scan(pattern)
        raise ParseError, "expected #{what} at position #{@scanner.pos}" if value.nil?

        value
      end

      def literal(value)
        raise ParseError, "expected '#{value}'" unless get == value
      end
      alias expect literal

      def skip(pattern)
        !@scanner.scan(pattern).nil?
      end

      def ws
        @scanner.scan(/[ \t\n\r]*/)
      end

      def get
        character = @scanner.getch
        raise ParseError, 'unexpected end of expression' if character.nil?

        character
      end

      def peek_char
        @scanner.eos? ? nil : @scanner.rest[0]
      end

      def peek?(value)
        @scanner.rest.start_with?(value)
      end

      def finish(what)
        ws
        raise ParseError, "unexpected characters in #{what}" unless @scanner.eos?
      end

      ascii_letter = ->(code) { (0x41..0x5A).cover?(code) || (0x61..0x7A).cover?(code) }
      name_first_ranges = [0x00C0..0x00D6, 0x00D8..0x00F6, 0x00F8..0x02FF,
                           0x0370..0x037D, 0x037F..0x1FFF, 0x200C..0x200D,
                           0x2070..0x218F, 0x2C00..0x2FEF, 0x3001..0xD7FF,
                           0xF900..0xFDCF, 0xFDF0..0xFFFD]
      NAME_START_RULE = ->(code) { ascii_letter.call(code) || code == 0x5F || name_first_ranges.any? { |range| range.cover?(code) } }
      NAME_CHAR_RULE = lambda do |code|
        NAME_START_RULE.call(code) || (0x30..0x39).cover?(code) ||
          code == 0x2D || code == 0x40 || code == 0x3A || code == 0x20
      end
      private_constant :COMPARISONS, :FUNCTIONS
    end
  end
end
