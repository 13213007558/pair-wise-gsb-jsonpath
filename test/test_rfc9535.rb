# frozen_string_literal: true

require 'minitest/autorun'
require 'phocus'
require 'jsonpath'
require 'json'

class TestRFC9535 < MiniTest::Test
  ParseError = JsonPath::RFC9535::ParseError

  def setup
    @object = {
      'store' => {
        'bicycle' => { 'price' => 19.95, 'color' => 'red' },
        'book' => [
          { 'price' => 8.95, 'category' => 'reference', 'title' => 'Sayings of the Century', 'author' => 'Nigel Rees' },
          { 'price' => 12.99, 'category' => 'fiction', 'title' => 'Sword of Honour', 'author' => 'Evelyn Waugh' },
          { 'price' => 8.99, 'category' => 'fiction', 'isbn' => '0-553-21311-3', 'title' => 'Moby Dick', 'author' => 'Herman Melville', 'color' => 'blue' },
          { 'price' => 22.99, 'category' => 'fiction', 'isbn' => '0-395-19395-8', 'title' => 'The Lord of the Rings', 'author' => 'Tolkien' }
        ]
      },
      'nullish' => nil,
      'falsy' => false,
      'truthy' => true
    }
  end

  def query(expression, object = @object)
    JsonPath::RFC9535::Query.new(expression).result(object)
  end

  def values(expression, object = @object)
    query(expression, object).map(&:first)
  end

  def paths(expression, object = @object)
    query(expression, object).map(&:last)
  end

  def test_root
    assert_equal [[@object, '$']], query('$')
  end

  def test_child_name_segment
    assert_equal [[19.95, "$['store']['bicycle']['price']"]],
                 query("$.store.bicycle.price")
  end

  def test_bracket_name_and_quote_styles
    assert_equal [19.95], values("$['store']['bicycle']['price']")
    assert_equal [19.95], values(%q($["store"]["bicycle"]["price"]))
  end

  def test_descendant_segment
    expected = [19.95, 8.95, 12.99, 8.99, 22.99]
    assert_equal expected, values('$..price')
    assert_equal(
      ["$['store']['bicycle']['price']",
       "$['store']['book'][0]['price']",
       "$['store']['book'][1]['price']",
       "$['store']['book'][2]['price']",
       "$['store']['book'][3]['price']"],
      paths('$..price')
    )
  end

  def test_descendant_dedupes_within_one_segment
    # Descendant traversal visits nodes once even when multiple paths reach them.
    result = values('$..book..price', @object)
    assert_equal result, result.uniq
  end

  def test_wildcard
    assert_equal [19.95, 'red'], values('$.store.bicycle.*')
    assert_equal [0, 1, 2, 3], paths('$.store.book[*]').map { |p| p[/\[(\d+)\]$/, 1].to_i }
  end

  def test_index_selectors_positive_and_negative
    assert_equal ['Sayings of the Century'], values('$.store.book[0].title')
    assert_equal ['The Lord of the Rings'], values('$.store.book[-1].title')
    assert_equal [], values('$.store.book[99].title')
    assert_equal [], values('$.store.book[-99].title')
  end

  def test_multiple_selectors_keep_order_and_duplicates
    books = @object['store']['book']
    assert_equal [books[0], books[2], books[0], books[3]],
                 values('$.store.book[0,2,0,3]')
  end

  def test_slice
    books = @object['store']['book']
    assert_equal [books[0], books[1]], values('$.store.book[0:2]')
    assert_equal [books[1], books[3]], values('$.store.book[1::2]')
    assert_equal [books[0], books[2]], values('$.store.book[::2]')
    assert_equal [books[3], books[1]], values('$.store.book[::-2]')
    assert_equal [books[2], books[3]], values('$.store.book[-2:]')
    assert_equal [], values('$.store.book[5:10]')
  end

  def test_slice_on_non_array_is_empty
    assert_equal [], values('$.store.bicycle[0:2]')
  end

  def test_filter_on_array_elements
    assert_equal [8.95, 8.99], values('$.store.book[?(@.price < 10)].price')
    assert_equal ['Sayings of the Century', 'Moby Dick'],
                 values('$.store.book[?(@.price < 10)].title')
  end

  def test_filter_with_and_or_not_and_parentheses
    books = @object['store']['book']
    assert_equal [books[2], books[3]], values('$.store.book[?(@.isbn)]')
    assert_equal [books[1], books[3]],
                 values('$.store.book[?(@.price > 10 && @.category == "fiction")]')
    assert_equal [books[0], books[1]],
                 values('$.store.book[?(!@.isbn)]')
    assert_equal [books[0], books[2], books[3]],
                 values('$.store.book[?(@.price < 10 || @.price > 20)]')
  end

  def test_filter_on_object_root
    assert_equal [@object], values('$[?(@.store)]')
    assert_equal [], values('$[?(@.missing)]')
  end

  def test_nothing_null_false_are_distinct
    # Existence tests only answer NodesType -> both null and false are existing nodes.
    assert_equal [@object], values('$[?(@.nullish)]')
    assert_equal [@object], values('$[?(@.falsy)]')
    assert_equal [], values('$[?(@.absent)]')
    # A singular query test for a missing member is false, so its negation is true.
    assert_equal [@object], values('$[?(!@.absent)]')

    # Equality against JSON null never matches a missing member (Nothing).
    assert_equal [@object], values('$[?(@.nullish == null)]')
    assert_equal [], values('$[?(@.absent == null)]')
    assert_equal [@object], values('$[?(@.absent != null)]')
    assert_equal [], values('$[?(@.nullish != null)]')

    # false is a real value and not equal to null or Nothing.
    assert_equal [@object], values('$[?(@.falsy == false)]')
    assert_equal [], values('$[?(@.falsy == null)]')
    assert_equal [@object], values('$[?(@.falsy != null)]')
    assert_equal [], values('$[?(@.absent == false)]')
  end

  def test_comparison_requires_singular_queries
    assert_raises(ParseError) { JsonPath::RFC9535::Query.new('$[?(@..price < 10)]') }
  end

  def test_duplicate_selection_is_not_deduplicated
    data = { 'book' => %w[a b] }
    assert_equal %w[a a a], values('$.book[0,0,0]', data)
    assert_equal [data['book'], data['book']], values('$..book', data.merge('other' => { 'book' => data['book'] }))
  end

  def test_count_function
    data = { 'a' => [1, 2, 3], 'b' => [1] }
    assert_equal [data], values('$[?(count(@.a[*]) == 3)]', data)
    assert_equal [data], values('$[?(count(@.missing[*]) == 0)]', data)
  end

  def test_length_function
    data = { 's' => 'abcde', 'arr' => [1, 2, 3], 'obj' => { 'x' => 1 }, 'num' => 7 }
    assert_equal [data], values(%q($[?(length(@.s) == 5)]), data)
    assert_equal [data], values(%q($[?(length(@.arr) == 3)]), data)
    assert_equal [data], values(%q($[?(length(@.obj) == 1)]), data)
    assert_equal [], values('$[?(length(@.num) > 0)]', data)
  end

  def test_value_function
    data = { 'x' => 4 }
    assert_equal [data], values('$[?(value(@.x) > 2)]', data)
    assert_raises(ParseError) { JsonPath::RFC9535::Query.new('$[?(value(@..*))]') }
  end

  def test_match_function
    data = { 't' => 'foobar' }
    assert_equal [data], values('$[?(match(@.t, "foo.*"))]', data)
    assert_equal [], values('$[?(match(@.t, "foo"))]', data)
  end

  def test_search_function
    data = { 't' => 'foobar' }
    assert_equal [data], values('$[?(search(@.t, "bar"))]', data)
    assert_equal [], values('$[?(search(@.t, "^bar"))]', data)
  end

  def test_function_argument_types_are_validated_at_parse_time
    assert_raises(ParseError) { JsonPath::RFC9535::Query.new('$[?(count(@.a, @.b))]') }
    assert_raises(ParseError) { JsonPath::RFC9535::Query.new('$[?(length())]') }
    assert_raises(ParseError) { JsonPath::RFC9535::Query.new('$[?(bogus(@.a))]') }
    assert_raises(ParseError) { JsonPath::RFC9535::Query.new('$[?(match(@.a, 1))]') }
    assert_raises(ParseError) { JsonPath::RFC9535::Query.new('$[?(count("x"))]') }
    assert_raises(ParseError) { JsonPath::RFC9535::Query.new('$[?(count(1))]') }
  end

  def test_count_in_filter_with_logical_operators
    data = { 'a' => [1, 2] }
    assert_equal [data], values('$[?(count(@.a[*]) == 2 && length(@.a) == 2)]', data)
  end

  def test_strings_with_parentheses_and_logical_operators
    value = 'a && b || c (d) [e] == !='
    data = { 't' => value }
    assert_equal [data], values(%q($[?(@.t == "a && b || c (d) [e] == !=")]), data)
    assert_equal [data], values(%q($[?(@.t == 'a && b || c (d) [e] == !=')]), data)
  end

  def test_quoted_names_with_special_characters
    data = { '$meta-data' => 1, 'Title Case' => 2, 'a.b' => 3 }
    assert_equal [1], values("$['$meta-data']", data)
    assert_equal [2], values("$['Title Case']", data)
    assert_equal [3], values("$['a.b']", data)
  end

  def test_unicode_shorthand_names
    data = { 'Übermögen' => 42, 'Übermorgen' => 43 }
    assert_equal [42], values('$.Übermögen', data)
    assert_equal [43], values('$.Übermorgen', data)
  end

  def test_normalized_path_escaping
    data = { "a'b" => { "c\\d" => nil, "\n" => 1 } }
    assert_equal ["$['a\\'b']"], paths("$[\"a'b\"]", data)
    assert_equal ["$['a\\'b']['c\\\\d']"], paths("$[\"a'b\"][\"c\\\\d\"]", data)
    assert_equal ["$['a\\'b']['\\n']"], paths("$[\"a'b\"][\"\\n\"]", data)
  end

  def test_whitespace_inside_brackets_and_filters
    assert_equal [1], values('$[ 0 ]', [1, 2])
    assert_equal [10], values('$[ ?( @.x  ==  10 ) ].v', [{ 'x' => 10, 'v' => 10 }, { 'x' => 5 }])
  end

  def test_invalid_paths_raise_parse_error
    invalid = ['.store', '$.', '$..', '$.a[', '$.a]', '$.a[0:1:0]',
               '$.a[?(@.x = 1)]', "$['a'", '$[01]', '$[1.5]', '$[]']
    invalid.each do |expression|
      assert_raises(ParseError, expression) { JsonPath::RFC9535::Query.new(expression) }
    end
  end

  def test_json_string_input
    json = '{"a": [1, 2]}'
    assert_equal [[[1, 2], "$['a']"]], query('$.a', json)
  end

  def test_descendant_collects_distinct_parents
    data = { 'a' => { 'x' => 1 }, 'b' => { 'x' => 1 } }
    assert_equal [1, 1], values("$..['x']", data)
    assert_equal ["$['a']['x']", "$['b']['x']"], paths("$..['x']", data)
  end

  def test_filter_with_nested_function_query
    data = { 'items' => [{ 'tags' => ['x'], 'v' => 1 }, { 'tags' => [], 'v' => 2 }] }
    assert_equal [1], values('$.items[?(count(@.tags[*]) > 0)].v', data)
  end

  def test_root_query_inside_filter_references_document_root
    data = { 'limit' => 3, 'items' => [1, 2, 4] }
    assert_equal [1, 2], values('$.items[?(@ < $.limit)]', data)
    nested = { 'threshold' => 10, 'book' => [{ 'title' => 'a', 'price' => 5 }, { 'title' => 'b', 'price' => 20 }] }
    assert_equal ['a'], values('$..book[?(@.price < $.threshold)].title', nested)
  end

  def test_count_counts_duplicate_selections
    data = { 'a' => [1, 2] }
    assert_equal [data], values('$[?(count(@.a[0,0,0]) == 3)]', data)
  end

  def test_match_anchors_fully_but_search_finds_substring
    data = [{ 't' => 'foo' }, { 't' => 'foobar' }, { 't' => 'xfoox' }]
    assert_equal [data[0]], values('$[?(match(@.t, "foo"))]', data)
    assert_equal data, values('$[?(search(@.t, "foo"))]', data)
  end

  def test_logical_and_or_with_missing_members
    data = [{ 'a' => true }, { 'a' => true, 'b' => true }, { 'b' => true }]
    assert_equal [data[1]], values('$[?(@.a && @.b)]', data)
    assert_equal data, values('$[?(@.a || @.b)]', data)
    assert_equal [], values('$[?(@.c || @.d)]', data)
  end

  def test_integrated_jsonpath_rfc9535_option
    path = JsonPath.new('$.store.book[0].title', rfc9535: true)
    assert_equal [['Sayings of the Century', "$['store']['book'][0]['title']"]], path.on(@object)
    assert_equal ['Sayings of the Century'], path.values(@object)
    assert_equal ["$['store']['book'][0]['title']"], path.paths(@object)
    assert_equal ['Sayings of the Century', "$['store']['book'][0]['title']"], path.first(@object)
  end

  def test_integrated_standard_alias
    path = JsonPath.new('$.store.bicycle.color', standard: true)
    assert_equal [['red', "$['store']['bicycle']['color']"]], path.on(@object)
  end

  def test_integrated_class_constructors
    query = JsonPath.rfc9535('$.store.book[*].author')
    assert_equal ['Nigel Rees', 'Evelyn Waugh', 'Herman Melville', 'Tolkien'], query.on(@object)
    assert_kind_of JsonPath::RFC9535::Query, JsonPath.standard('$')
  end

  def test_legacy_mode_remains_compatible
    # Legacy syntax that differs from RFC stays intact.
    assert_equal [8.95, 8.99],
                 JsonPath.new("$..book[?(@['price'] < 10)]").on(@object).map { |b| b['price'] }.sort
    assert_equal [8.95], JsonPath.new('$.store.book[0].price').on(@object)
  end

  def test_legacy_enumerable_modes_rejected_in_rfc_mode
    path = JsonPath.new('$.a', rfc9535: true)
    assert_raises(ArgumentError) { path['{"a":1}', :delete] }
  end

  def test_symbolize_keys_option
    data = { 'a' => { 'b' => 1 } }
    result = JsonPath.new('$.a', rfc9535: true).on(data, symbolize_keys: true)
    assert_equal [[{ b: 1 }, "$['a']"]], result
  end

  def test_each_pair_yields_value_and_path
    collected = []
    JsonPath.new('$.a[*]', rfc9535: true).each_pair({ 'a' => [10, 20] }) do |value, path|
      collected << [path, value]
    end
    assert_equal [["$['a'][0]", 10], ["$['a'][1]", 20]], collected
  end
end
