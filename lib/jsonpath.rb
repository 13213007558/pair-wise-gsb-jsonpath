# frozen_string_literal: true

require 'strscan'
require 'multi_json'
require 'jsonpath/proxy'
require 'jsonpath/dig'
require 'jsonpath/enumerable'
require 'jsonpath/version'
require 'jsonpath/parser'
require 'jsonpath/rfc9535/query'

# JsonPath: initializes the class with a given JsonPath and parses that path
# into a token array.
class JsonPath
  PATH_ALL = '$..*'
  MAX_NESTING_ALLOWED = 100

  DEFAULT_OPTIONS = {
    :default_path_leaf_to_null => false,
    :symbolize_keys => false,
    :use_symbols => false,
    :allow_send => true,
    :max_nesting => MAX_NESTING_ALLOWED,
    :rfc9535 => false
  }

  attr_accessor :path

  def initialize(path, opts = {})
    @opts = DEFAULT_OPTIONS.merge(opts)
    set_max_nesting
    @rfc9535 = @opts[:rfc9535] || @opts[:standard]
    if @rfc9535
      @path = path
      @rfc_query = RFC9535::Query.new(path.strip)
      return
    end
    scanner = StringScanner.new(path.strip)
    @path = []
    until scanner.eos?
      if (token = scanner.scan(/\$\B|@\B|\*|\.\./))
        @path << token
      elsif (token = scanner.scan(/[$@\p{Alnum}:{}_ -]+/))
        @path << "['#{token}']"
      elsif (token = scanner.scan(/'(.*?)'/))
        @path << "[#{token}]"
      elsif (token = scanner.scan(/\[/))
        @path << find_matching_brackets(token, scanner)
      elsif (token = scanner.scan(/\]/))
        raise ArgumentError, 'unmatched closing bracket'
      elsif (token = scanner.scan(/\(.*\)/))
        @path << token
      elsif scanner.scan(/\./)
        nil
      elsif (token = scanner.scan(/[><=] \d+/))
        @path.last << token
      elsif (token = scanner.scan(/./))
        @path.last << token
      else
        raise ArgumentError, "character '#{scanner.peek(1)}' not supported in query"
      end
    end
  end

  def find_matching_brackets(token, scanner)
    count = 1
    until count.zero?
      if (t = scanner.scan(/\[/))
        token << t
        count += 1
      elsif (t = scanner.scan(/\]/))
        token << t
        count -= 1
      elsif (t = scanner.scan(/[^\[\]]+/))
        token << t
      elsif scanner.eos?
        raise ArgumentError, 'unclosed bracket'
      end
    end
    token
  end

  def join(join_path)
    if @rfc9535
      return self.class.new("#{@path}#{join_path}", rfc9535_options)
    end
    res = deep_clone
    res.path += JsonPath.new(join_path).path
    res
  end

  def on(obj_or_str, opts = {})
    return @rfc_query.result_with_options(self.class.process_object(obj_or_str, @opts), opts) if @rfc9535
    a = enum_on(obj_or_str).to_a
    if symbolize_keys?(opts)
      a.map! do |e|
        e.each_with_object({}) { |(k, v), memo| memo[k.to_sym] = v; }
      end
    end
    a
  end

  # RFC 9535 mode: returns [value, Normalized Path] pairs.
  def result(obj_or_str, opts = {})
    raise ArgumentError, '#result is only available in RFC 9535 mode; use #on for values' unless @rfc9535

    @rfc_query.result_with_options(self.class.process_object(obj_or_str, @opts), opts)
  end

  # RFC 9535 mode: returns only Normalized Paths.
  def paths(obj_or_str, opts = {})
    raise ArgumentError, 'paths is only available in RFC 9535 mode' unless @rfc9535

    @rfc_query.paths(self.class.process_object(obj_or_str, @opts))
  end

  # RFC 9535 mode: returns only values.
  def values(obj_or_str, opts = {})
    return @rfc_query.values(self.class.process_object(obj_or_str, @opts)) if @rfc9535

    on(obj_or_str, opts)
  end

  # RFC 9535 mode: yields [value, Normalized Path] pairs.
  def each_pair(obj_or_str, &blk)
    raise ArgumentError, '#each_pair is only available in RFC 9535 mode' unless @rfc9535

    @rfc_query.each(self.class.process_object(obj_or_str, @opts), &blk)
  end

  def self.fetch_all_path(obj)
    all_paths = ['$']
    find_path(obj, '$', all_paths, obj.class == Array)
    return all_paths
  end

  def self.find_path(obj, root_key, all_paths, is_array = false)
    obj.each do |key, value|
      table_params = { key: key, root_key: root_key}
      is_loop = value.class == Array || value.class == Hash
      if is_loop
        path_exp = construct_path(table_params)
        all_paths << path_exp
        find_path(value, path_exp, all_paths, value.class == Array)
      elsif is_array
        table_params[:index] = obj.find_index(key)
        path_exp = construct_path(table_params)
        find_path(key, path_exp, all_paths, key.class == Array) if key.class == Hash || key.class == Array
        all_paths << path_exp
      else
        all_paths << construct_path(table_params)
      end
    end
  end

  def self.construct_path(table_row)
    if table_row[:index]
      return table_row[:root_key] + '['+ table_row[:index].to_s + ']'
    else
      return table_row[:root_key] + '.'+ table_row[:key]
    end
  end

  def first(obj_or_str, *args)
    return @rfc_query.first(self.class.process_object(obj_or_str, @opts)) if @rfc9535
    enum_on(obj_or_str).first(*args)
  end

  def enum_on(obj_or_str, mode = nil)
    raise ArgumentError, 'legacy modes are not available in RFC 9535 mode' if @rfc9535 && mode
    JsonPath::Enumerable.new(self, self.class.process_object(obj_or_str, @opts), mode,
                             @opts)
  end
  alias [] enum_on

  def self.on(obj_or_str, path, opts = {})
    new(path, opts).on(process_object(obj_or_str))
  end

  # Creates an independent RFC 9535 (standard JSONPath) query.
  def self.rfc9535(path)
    RFC9535::Query.new(path)
  end
  class << self
    alias standard rfc9535
  end

  def self.for(obj_or_str)
    Proxy.new(process_object(obj_or_str))
  end

  private

  def rfc_query
    @rfc_query
  end

  def rfc9535_options
    @opts.merge(:rfc9535 => true)
  end

  def self.process_object(obj_or_str, opts = {})
    obj_or_str.is_a?(String) ? MultiJson.decode(obj_or_str, max_nesting: opts[:max_nesting]) : obj_or_str
  end

  def deep_clone
    Marshal.load Marshal.dump(self)
  end

  def set_max_nesting
    return unless @opts[:max_nesting].is_a?(Integer) && @opts[:max_nesting] > MAX_NESTING_ALLOWED
    @opts[:max_nesting] = false
  end

  def symbolize_keys?(opts)
    opts.fetch(:symbolize_keys, @opts&.dig(:symbolize_keys))
  end
end
