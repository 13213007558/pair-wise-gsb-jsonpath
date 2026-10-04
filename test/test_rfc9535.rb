# frozen_string_literal: true

require 'minitest/autorun'
require 'jsonpath'
require 'json'

class TestRFC9535 < Minitest::Test
  STORE = {
    'store' => {
      'book' => [
        { 'category' => 'reference', 'author' => 'Nigel Rees', 'price' => 8.95 },
        { 'category' => 'fiction', 'author' => 'Evelyn Waugh', 'price' => 12.99 },
        { 'category' => 'fiction', 'isbn' => '0-553-21311-3', 'price' => 8.99 },
        { 'category' => 'fiction', 'isbn' => '0-395-19395-8', 'price' => 22.99 }
      ],
      'bicycle' => { 'color' => 'red', 'price' => 19.95 }
    }
  }.freeze

  def values(query, object = STORE)
    JsonPath::RFC9535.on(object, query)
  end

  def paths(query, object = STORE)
    JsonPath::RFC9535.paths(object, query)
  end

  def results(query, object = STORE)
    JsonPath::RFC9535.result(object, query)
  end

  # -------------------------------------------------------------
  # Child / descendant segments
  # -------------------------------------------------------------

  def test_root_alone
    assert_equal [STORE], values('$')
    assert_equal ['$'], paths('$')
  end

  def test_dotted_and_bracketed_child_names_are_equivalent
    assert_equal [8.95], values("$.store.book[0]['price']")
    assert_equal [8.95], values('$.store.book[0].price')
  end

  def test_name_with_special_characters_uses_brackets
    assert_equal [1], values('$["a-b c"]', { 'a-b c' => 1 })
  end

  def test_descendant_collects_in_document_order
    # Members in insertion order (book precedes bicycle), nodes depth-first.
    assert_equal [8.95, 12.99, 8.99, 22.99, 19.95], values('$..price')
  end

  def test_descendant_wildcard
    object = { 'a' => { 'x' => 1 }, 'b' => 2 }
    assert_equal [{ 'x' => 1 }, 2, 1], values('$..*', object)
  end

  def test_descendant_bracket_name
    object = { 'a' => { 'x' => 1 }, 'c' => { 'x' => 2 } }
    assert_equal [1, 2], values("$..['x']", object)
  end

  def test_whitespace_only_inside_brackets
    assert_equal [8.95], values("$[ 'store' ][ 'book' ][ 0 ][ 'price' ]")
    assert_raises(JsonPath::RFC9535::ParseError) { values("$ ['store']") }
  end

  def test_missing_name_is_nothing_not_null
    assert_equal [], values('$.missing')
    assert_equal [], values('$.store.missing.whatever')
  end

  # -------------------------------------------------------------
  # Indices and slices
  # -------------------------------------------------------------

  def test_index_positive_and_negative
    assert_equal ['reference'], values('$.store.book[-4].category')
    assert_equal [22.99], values('$.store.book[-1].price')
    assert_equal [], values('$.store.book[99].price')
    assert_equal [], values('$.store.book[-99].price')
  end

  def test_slice_end_is_exclusive
    assert_equal [8.95, 12.99], values('$.store.book[0:2].price')
  end

  def test_slice_open_bounds
    assert_equal [8.95, 12.99, 8.99], values('$.store.book[:3].price')
    assert_equal [8.99, 22.99], values('$.store.book[-2:].price')
  end

  def test_slice_step_and_reversal
    assert_equal [8.95, 8.99], values('$.store.book[::2].price')
    assert_equal [22.99, 8.99, 12.99, 8.95], values('$.store.book[::-1].price')
    assert_equal [22.99, 8.99], values('$.store.book[3:1:-1].price')
  end

  def test_slice_on_object_is_nothing
    assert_equal [], values('$.store[0:2]')
  end

  def test_index_leading_zeros_are_rejected
    assert_raises(JsonPath::RFC9535::ParseError) { values('$[01]') }
  end

  def test_slice_step_zero_is_rejected
    assert_raises(JsonPath::RFC9535::ParseError) { values('$[::0]') }
  end

  # -------------------------------------------------------------
  # Multiple selectors and no auto-deduplication across queries
  # -------------------------------------------------------------

  def test_multiple_name_selectors
    object = { 'a' => 1, 'b' => 2, 'c' => 3 }
    assert_equal [1, 3], values("$['a','c']", object)
  end

  def test_duplicate_selector_in_one_segment_is_collapsed
    object = { 'a' => 1, 'b' => 2 }
    assert_equal [1], values("$['a','a']", object)
  end

  def test_repeated_node_selection_is_not_deduplicated
    object = { 'a' => { 'x' => 1 }, 'b' => { 'x' => 1 } }
    # Each input node selects @..x; identical values stay distinct and order
    # follows the input node list.
    assert_equal [[1, 1]], [values('$..x', object)]
    assert_equal 2, values('$..x', object).size
  end

  # -------------------------------------------------------------
  # Filters
  # -------------------------------------------------------------

  def test_filter_comparisons
    assert_equal ['reference', 'fiction'], values('$.store.book[?@.price < 10].category')
    assert_equal [8.95, 8.99, 22.99], values('$.store.book[?@.price != 12.99].price')
    assert_equal [12.99, 22.99], values('$.store.book[?@.price >= 12.99].price')
  end

  def test_filter_and_or_not_and_groups
    books = '$.store.book'
    assert_equal [8.95], values("#{books}[?@.price < 10 && @.category == 'reference'].price")
    assert_equal [8.95, 22.99], values("#{books}[?@.category == 'reference' || @.price > 20].price")
    assert_equal [12.99, 8.99, 22.99], values("#{books}[?!( @.category == 'reference' )].price")
    assert_equal [8.95], values("#{books}[?(@.price < 10 && @.category == 'reference')].price")
  end

  def test_nothing_null_false_are_distinct
    object = [
      { 'name' => 'nothing' },
      { 'name' => 'null', 'flag' => nil },
      { 'name' => 'false', 'flag' => false },
      { 'name' => 'zero', 'flag' => 0 },
      { 'name' => 'emptystring', 'flag' => '' }
    ]
    # LogicalType of a singular query: null/false convert to false, while a
    # non-singular query only checks that the node list is non-empty.
    assert_equal %w[zero emptystring],
                 values('$[?@.flag]', object).map { |o| o['name'] }
    assert_equal %w[null false zero emptystring],
                 values('$[?@..flag]', object).map { |o| o['name'] }
    # Equality against null only matches the explicit JSON null value.
    assert_equal ['null'], values('$[?@.flag == null]', object).map { |o| o['name'] }
    assert_equal %w[false zero emptystring],
                 values('$[?@.flag != null]', object).map { |o| o['name'] }
    # Equality against false only matches the actual boolean false.
    assert_equal ['false'], values('$[?@.flag == false]', object).map { |o| o['name'] }
    # Nothing from a missing singular query never equals (or differs from).
    assert_equal [], values('$[?@.missing == 0]', object)
    assert_equal [], values('$[?@.missing != 0]', object)
  end

  def test_filter_string_with_parentheses_and_operators
    object = [{ 'note' => 'foo (bar) && baz || qux' }, { 'note' => 'other' }]
    assert_equal ['foo (bar) && baz || qux'],
                 values("$[?@.note == 'foo (bar) && baz || qux'].note", object)
  end

  def test_filter_double_quoted_string
    object = [{ 's' => 'a&&b||c' }]
    assert_equal ['a&&b||c'], values('$[?@.s == "a&&b||c"].s', object)
  end

  def test_filter_string_escapes
    object = [{ 's' => "a'b\nc" }]
    assert_equal ["a'b\nc"], values(%q($[?@.s == 'a\'b\nc'].s), object)
  end

  def test_root_query_inside_filter
    object = { 'threshold' => 10, 'nums' => [5, 15] }
    assert_equal [15], values('$.nums[?@ >= $.threshold]', object)
  end

  def test_nested_filter_query
    object = { 'a' => [1, 2], 'b' => [{ 'x' => [9] }, { 'x' => [1] }] }
    assert_equal [{ 'x' => [9] }], values('$.b[?@.x[0] > 5]', object)
  end

  def test_filter_on_object_selects_member_values
    object = { 'keep' => 1, 'drop' => 2 }
    # Filtering an object tests the object as a whole: @ is bound to the
    # object, and the whole object is selected when the test passes.
    assert_equal [object], values('$[?@.keep == 1]', object)
    assert_equal [], values('$[?@.absent]', object)
  end

  # -------------------------------------------------------------
  # Standard functions and declared argument types
  # -------------------------------------------------------------

  def test_length_on_string_array_object
    assert_equal [{ 'name' => 'hello' }], values('$[?length(@.name) == 5]', [{ 'name' => 'hello' }])
    assert_equal [[1, 2, 3]], values('$[?length(@.items) == 3].items', [{ 'items' => [1, 2, 3] }])
    assert_equal [{ 'obj' => { 'a' => 1, 'b' => 2 } }],
                 values('$[?length(@.obj) == 2]', [{ 'obj' => { 'a' => 1, 'b' => 2 } }])
    assert_equal [], values('$[?length(@.missing) == 0]', [{ 'a' => 1 }])
  end

  def test_count
    # Filter iterates array elements, so count the root array from a member
    # using a root query instead.
    object = { 'rows' => [[1, 2, 3], [9]] }
    assert_equal [[1, 2, 3]], values('$.rows[?count(@[*]) == 3]', object)
  end

  def test_value_function
    object = [{ 'a' => 1 }, { 'a' => 2 }]
    assert_equal [2], values('$[?value(@..a) > 1].a', object)
  end

  def test_match_full_anchored
    object = [{ 's' => 'hello' }, { 's' => 'say hello' }]
    assert_equal ['hello'], values("$[?match(@.s, 'hel.o')].s", object)
  end

  def test_search_unanchored
    object = [{ 's' => 'say hello' }, { 's' => 'nope' }]
    assert_equal ['say hello'], values("$[?search(@.s, 'hel.o')].s", object)
  end

  def test_function_arguments_are_type_checked
    assert_raises(JsonPath::RFC9535::ParseError) { values('$[?count(@.x) == 1]', {}) }
    assert_raises(JsonPath::RFC9535::ParseError) { values('$[?length(@..x) == 1]', {}) }
    assert_raises(JsonPath::RFC9535::ParseError) { values("$[?match(@.s, 1)]", {}) }
    assert_raises(JsonPath::RFC9535::ParseError) { values('$[?count(1) == 1]', {}) }
    assert_raises(JsonPath::RFC9535::ParseError) { values("$[?length(match(@.s, 'x')) == 1]", {}) }
    assert_raises(JsonPath::RFC9535::ParseError) { values("$[?count(match(@.s, 'x'))]", {}) }
  end

  def test_unknown_function_is_rejected
    assert_raises(JsonPath::RFC9535::ParseError) { values('$[?foo(@)]', {}) }
  end

  # -------------------------------------------------------------
  # Normalized paths
  # -------------------------------------------------------------

  def test_normalized_paths
    assert_equal ["$['store']['book'][0]['price']"], paths('$.store.book[0].price')
  end

  def test_normalized_path_escaping
    object = { "a'b" => { "c\nd" => 1 } }
    assert_equal ["$['a\\'b']['c\\nd']"], paths("$[\"a'b\"][\"c\\nd\"]", object)
  end

  def test_result_pairs_value_and_path
    pairs = results('$.store.book[*].price').map { |r| [r.value, r.normalized_path] }
    assert_equal [[8.95, "$['store']['book'][0]['price']"],
                  [12.99, "$['store']['book'][1]['price']"]], pairs.first(2)
    result = results('$.store.book[0].price').first
    assert_equal 8.95, result.value
    assert_equal result.normalized_path, result.path
  end

  # -------------------------------------------------------------
  # Parser error behavior
  # -------------------------------------------------------------

  def test_malformed_queries_raise_parse_error
    ['', '@.x', '$.', '$[', '$.a[', "$['a'", '$[?', '$[?@.', '$$', '$.a..'].each do |query|
      assert_raises(JsonPath::RFC9535::ParseError, query) { values(query) }
    end
  end

  # -------------------------------------------------------------
  # Integration with JsonPath class and compatibility
  # -------------------------------------------------------------

  def test_instance_option_enables_rfc_mode
    query = JsonPath.new('$.store.book[0].price', rfc9535: true)
    assert query.rfc9535?
    assert_equal [8.95], query.on(STORE)
    assert_equal ["$['store']['book'][0]['price']"], query.paths_on(STORE)
    assert_equal [8.95], query.result_on(STORE).map(&:value)
    assert_kind_of Enumerable, query[STORE]
    assert_equal 8.95, query.first(STORE)
  end

  def test_legacy_mode_is_unchanged
    query = JsonPath.new('$..price')
    refute query.rfc9535?
    assert_equal [19.95, 8.95, 12.99, 8.99, 22.99].sort, query.on(STORE).sort
    assert_raises(ArgumentError) { query.result_on(STORE) }
  end

  def test_class_result_on
    result = JsonPath.result_on(STORE, '$..book[-1].price')
    assert_equal [22.99], result.map(&:value)
    assert_equal ["$['store']['book'][3]['price']"], result.map(&:normalized_path)
  end

  def test_module_accepts_json_string
    json = STORE.to_json
    assert_equal [8.95], JsonPath::RFC9535.on(json, '$.store.book[0].price')
  end
end

class TestRFC9535Requirements < Minitest::Test
  def values(object, query)
    JsonPath::RFC9535.on(object, query)
  end

  def test_parentheses_and_operators_inside_strings_are_literal
    tricky = [
      { 'expr' => '(a && b) || (c)' },
      { 'expr' => 'plain' },
      { 'expr' => 'x[?@.y] == z' }
    ]
    selected = values(tricky, %q($[?@.expr == '(a && b) || (c)'].expr))
    assert_equal ['(a && b) || (c)'], selected
    selected = values(tricky, %q($[?@.expr == 'x[?@.y] == z'].expr))
    assert_equal ['x[?@.y] == z'], selected
  end

  def test_repeated_selection_is_preserved_across_descendants
    tree = { 'a' => { 'leaf' => 1 }, 'b' => { 'leaf' => 1 } }
    result = JsonPath::RFC9535.result(tree, '$..leaf')
    assert_equal [1, 1], result.map(&:value)
    assert_equal ["$['a']['leaf']", "$['b']['leaf']"], result.map(&:normalized_path)
  end

  def test_identical_node_selected_twice_is_returned_twice
    object = { 'list' => [42, 42, 42] }
    assert_equal [42, 42, 42], values(object, '$.list[*]')
  end

  def test_nothing_vs_null_vs_false_in_comparisons
    rows = [
      { 'id' => 'missing' },
      { 'id' => 'null', 'v' => nil },
      { 'id' => 'false', 'v' => false },
      { 'id' => 'zero', 'v' => 0 },
      { 'id' => 'empty', 'v' => '' }
    ]
    assert_equal ['null'], values(rows, '$[?@.v == null]').map { |r| r['id'] }
    assert_equal ['false'], values(rows, '$[?@.v == false]').map { |r| r['id'] }
    # Different primitive types are unequal, so false/0/'' all differ from null.
    assert_equal %w[false zero empty], values(rows, '$[?@.v != null]').map { |r| r['id'] }
    assert_equal [], values(rows, '$[?@.v == 1]')
    assert_equal [], values(rows, '$[?@.unknown == null]')
    assert_equal ['zero'], values(rows, '$[?@.v == 0]').map { |r| r['id'] }
  end

  def test_function_argument_type_enforcement
    assert_raises(JsonPath::RFC9535::ParseError) { values({}, '$[?count(@.singular)]') }
    assert_raises(JsonPath::RFC9535::ParseError) { values({}, '$[?length(@..many)]') }
    assert_raises(JsonPath::RFC9535::ParseError) { values({}, "$[?search(@.s, 42)]") }
    assert_raises(JsonPath::RFC9535::ParseError) { values({}, "$[?count(search(@.s, 'x'))]") }
  end
end
