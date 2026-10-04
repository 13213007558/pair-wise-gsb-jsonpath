# frozen_string_literal: true

require 'minitest/autorun'
require 'phocus'
require 'jsonpath'

class TestJsonpathBin < MiniTest::Unit::TestCase
  def setup
    @runner = 'ruby -Ilib bin/jsonpath'
    @original_dir = Dir.pwd
    Dir.chdir(File.join(File.dirname(__FILE__), '..'))
  end

  def teardown
    Dir.chdir(@original_dir)
    `rm /tmp/test.json`
  end

  def test_stdin
    File.open('/tmp/test.json', 'w') { |f| f << '{"test": "time"}' }
    assert_equal '["time"]', `#{@runner} '$.test' /tmp/test.json`.strip
  end

  def test_rfc9535_outputs_value_and_normalized_path
    File.open('/tmp/test.json', 'w') { |f| f << '{"a": {"b": 1}}' }
    expected = '[[1,"$[\'a\'][\'b\']"]]'
    assert_equal expected, `#{@runner} --rfc9535 '$..b' /tmp/test.json`.strip
  end
end
