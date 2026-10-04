# frozen_string_literal: true

require 'multi_json'
require 'jsonpath/rfc9535/ast'
require 'jsonpath/rfc9535/parser'
require 'jsonpath/rfc9535/evaluator'
require 'jsonpath/rfc9535/enumerable'

class JsonPath
  # Independent RFC 9535 (JSONPath) implementation. It is kept separate from
  # the historical goessner-based mode so that enabling the standard changes
  # no existing behavior.
  module RFC9535
    module_function

    # Apply +query+ and return Result objects carrying both the selected value
    # and its Normalized Path.
    def result(object_or_json, query)
      object = decode(object_or_json)
      RFC9535::Enumerable.new(Parser.parse(query), object).results
    end

    # Apply +query+ and return only the selected values.
    def on(object_or_json, query)
      result(object_or_json, query).map(&:value)
    end

    # Apply +query+ and return only the Normalized Paths.
    def paths(object_or_json, query)
      result(object_or_json, query).map(&:normalized_path)
    end

    def decode(object_or_json)
      object_or_json.is_a?(String) ? MultiJson.decode(object_or_json) : object_or_json
    end
  end
end
