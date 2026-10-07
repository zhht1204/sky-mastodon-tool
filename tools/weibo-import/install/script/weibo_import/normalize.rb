# frozen_string_literal: true

# JSON → JSONL 规范化（纯 Ruby，不依赖 Rails）。
# 契约：source_id 全程字符串；时间保真（带偏移尊重原偏移，无偏移用 default tz，
# 无法解析/未来/早于 2009 一律进错误清单，绝不用当前时间顶替）；
# 可见性只能收紧不能放宽；HTML 只做转文本，绝不执行任何脚本。
require 'json'
require 'digest'
require 'time'
require 'date'
require_relative 'adapter'

module WeiboImport
  module Normalize
    class RecordError < StandardError; end

    MIN_TIME = Time.utc(2009, 1, 1) # 微博 2009-08 上线；更早视为数据异常
    FUTURE_SLOP_SECONDS = 24 * 60 * 60 # 允许 1 天时钟偏差，超过视为未来时间

    # 固定偏移别名（大写键）。DST 地区请直接显式传 ±HH:MM，本表不做夏令时推算。
    TZ_ALIASES = {
      'UTC' => '+00:00', 'GMT' => '+00:00',
      'ASIA/SHANGHAI' => '+08:00', 'ASIA/CHONGQING' => '+08:00', 'ASIA/HARBIN' => '+08:00',
      'ASIA/TAIPEI' => '+08:00', 'ASIA/HONG_KONG' => '+08:00', 'ASIA/MACAU' => '+08:00',
      'ASIA/SINGAPORE' => '+08:00', 'ASIA/TOKYO' => '+09:00', 'ASIA/SEOUL' => '+09:00',
      'EUROPE/LONDON' => '+00:00'
    }.freeze

    JSON_OPTS = { max_nesting: 200, allow_nan: false, create_additions: false }.freeze
    OFFSET_RE = /\A([+-])(\d{2}):?(\d{2})\z/
    HAS_OFFSET_RE = /(?:Z|[+-]\d{2}:?\d{2})\z/
    TIME_HINT_RE = /\A\d{4}[-\/]\d{1,2}[-\/]\d{1,2}([T ]\d{1,2}:\d{2}(:\d{2})?)?|\A\d{10,13}\z/
    GRAPHHEME_RE = /\X/.freeze

    module_function

    # ---- 时区与时间 ---------------------------------------------------------------

    def resolve_tz(name)
      s = name.to_s.strip
      return '+08:00' if s.empty? # 缺省按微博主时区（调用方显式传 --default-tz 覆盖）
      m = s.match(OFFSET_RE)
      return "#{m[1]}#{m[2]}:#{m[3]}" if m

      alias_offset = TZ_ALIASES[s.upcase]
      return alias_offset if alias_offset

      raise ArgumentError, "未知时区 #{s.inspect}: 请使用固定偏移（如 +08:00）或内置别名（Asia/Shanghai、UTC 等）"
    end

    def tz_offset_seconds(offset_str)
      m = offset_str.to_s.match(/\A([+-])(\d{2}):(\d{2})\z/)
      raise ArgumentError, "非法时区偏移: #{offset_str.inspect}" unless m

      sec = m[2].to_i * 3600 + m[3].to_i * 60
      m[1] == '-' ? -sec : sec
    end

    # 返回 { time: Time, zone: String( zone 描述 ) }；失败抛 RecordError
    def parse_time(raw, default_offset: '+08:00', now: nil)
      now ||= Time.now
      time =
        case raw
        when Time then raw
        when Date then Time.utc(raw.year, raw.month, raw.day)
        when DateTime then
          off = (raw.offset * 86_400).to_i
          offset_str = format('%+03d:%02d', off / 3600, (off % 3600) / 60)
          Time.new(raw.year, raw.mon, raw.day, raw.hour, raw.min, raw.sec, offset_str)
        when Integer, Float then epoch_to_time(raw, zone: 'epoch→UTC')
        when String then parse_time_string(raw, default_offset)
        else raise RecordError, "时间值类型不支持: #{raw.class}"
        end
      validate_time_window(time, now)
      time
    end

    def epoch_to_time(v, zone: 'epoch→UTC')
      f = v.to_f
      if f >= 1e9 && f < 1e10
        Time.at(f).utc
      elsif f >= 1e11 && f < 1e14
        Time.at(f / 1000.0).utc
      else
        raise RecordError, "epoch 时间戳量级异常: #{v}"
      end
    end

    def parse_time_string(str, default_offset)
      s = str.strip
      raise RecordError, '时间字符串为空' if s.empty?

      return epoch_to_time(s.to_f) if s.match?(/\A\d+(\.\d+)?\z/)

      normalized = s.sub(/\A(\d{4}-\d{2}-\d{2})[ ]/, '\1T')
      has_offset = normalized.match?(HAS_OFFSET_RE)
      normalized = normalized.sub(/([+-]\d{2})(\d{2})\z/, '\1:\2') # +0800 → +08:00

      begin
        if has_offset
          # 不用 Time.iso8601：它会按宿主机本地时区重表示；这里显式保留来源偏移
          dt = DateTime.parse(normalized)
          off = (dt.offset * 86_400).to_i
          offset_str = format('%+03d:%02d', off / 3600, (off % 3600) / 60)
          t = Time.new(dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec, offset_str)
        else
          dt = DateTime.parse(normalized) # 宽松兜底（2017/05/06 07:08 等常见导出格式）
          t = Time.new(dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec, default_offset)
        end
      rescue ArgumentError, Date::Error
        raise RecordError, "无法解析时间: #{str.inspect}"
      end
      t
    end

    def validate_time_window(t, now)
      # Time#utc/gmtime 会就地改变时区表示（返回 self），必须用 getutc 做非变异比较，
      # 否则带原偏移的 Time 在校验后被就地转成 UTC，破坏“尊重原偏移”的输出契约
      tu = t.getutc
      raise RecordError, "时间早于 2009-01-01（疑似数据异常）: #{tu.iso8601}" if tu < MIN_TIME
      raise RecordError, "未来时间（超出 24h 容差）: #{tu.iso8601}" if tu > now.getutc + FUTURE_SLOP_SECONDS

      t
    end

    # ---- 单条规范化 ---------------------------------------------------------------

    def normalize_record(record, map, index: nil, original_line: nil, default_offset: nil, now: nil)
      default_offset ||= resolve_tz(map.timezone)
      ex = map.extract(record)
      raise RecordError, "缺少 ID 字段 #{map.id_field.inspect}" if ex.source_id.nil? || ex.source_id.empty?
      raise RecordError, "缺少时间字段 #{map.created_at_field.inspect}" if ex.created_at_raw.nil?
      raise RecordError, "缺少正文字段 #{map.text_field.inspect}" if ex.text_raw.nil?
      raise RecordError, ex.media_error if ex.media_error

      zone_used = time_zone_of(ex.created_at_raw, default_offset)
      time = parse_time(ex.created_at_raw, default_offset: default_offset, now: now)

      text = ex.text_html ? html_to_text(ex.text_raw) : ex.text_raw.to_s
      text = text.gsub(/\r\n/, "\n")

      visibility = resolve_visibility(ex.visibility_raw, map)
      reply_to = ex.reply_to_raw.nil? ? nil : ex.reply_to_raw.to_s
      repost = repost_flag?(ex.repost_raw, map) ? truncate_graphemes(ex.repost_quote_raw.to_s.strip, 200) : nil
      raw_bytes = original_line || canonical_json(record)

      {
        'source' => map.source,
        'source_id' => ex.source_id,
        'source_url' => ex.source_url,
        'created_at' => time.iso8601,
        'text' => text,
        'visibility' => visibility,
        'media' => ex.media_items || [],
        'reply_to_source_id' => reply_to,
        'repost' => repost,
        'raw_record_sha256' => Digest::SHA256.hexdigest(raw_bytes),
        'extra' => {
          'source_created_at_raw' => ex.created_at_raw.to_s,
          'source_tz' => zone_used,
          'created_at_utc' => time.utc.iso8601
        }
      }
    end

    def time_zone_of(raw, default_offset)
      return 'epoch→UTC' if raw.is_a?(Integer) || raw.is_a?(Float)
      s = raw.to_s
      return 'epoch→UTC' if s.match?(/\A\d+(\.\d+)?\z/)

      s.match?(HAS_OFFSET_RE) ? '原偏移' : "default#{default_offset}"
    end

    def resolve_visibility(raw, map)
      cfg = map.visibility_cfg
      return cfg['default'].to_s.empty? ? 'unlisted' : cfg['default'].to_s if raw.nil?

      target = (cfg['mapping'] || {})[raw.to_s]
      raise RecordError, "未声明的可见性取值: #{raw.to_s.inspect}（请在 field_map.yml 的 visibility.mapping 补全）" if target.nil?

      target.to_s
    end

    def repost_flag?(raw, map)
      return false if raw.nil?

      truthy = map.repost_truthy
      truthy.include?(raw) || truthy.include?(raw.to_s)
    end

    # ---- HTML → 纯文本（绝不执行任何脚本/样式；只做字符串变换）--------------------

    ENTITY_MAP = {
      '&amp;' => '&', '&lt;' => '<', '&gt;' => '>', '&quot;' => '"',
      '&apos;' => "'", '&nbsp;' => ' ', '&copy;' => '©', '&hellip;' => '…'
    }.freeze

    def html_to_text(html)
      text = html.to_s
      text = text.gsub(%r{<br\s*/?>}i, "\n")
      text = text.gsub(%r{</(?:p|div|li|tr|h[1-6]|blockquote|section|article)>}i, "\n")
      text = text.gsub(/<img\b[^>]*\balt=["']([^"']*)["'][^>]*>/i) { Regexp.last_match(1).empty? ? '' : "【图:#{Regexp.last_match(1)}】" }
      text = text.gsub(/<a\b[^>]*\bhref=["']([^"']+)["'][^>]*>(.*?)<\/a>/im) do
        href = Regexp.last_match(1)
        inner = Regexp.last_match(2).gsub(%r{<[^>]+>}, '').strip
        href == inner || inner.empty? ? href : "#{inner} (#{href})"
      end
      text = text.gsub(/<[^>]+>/, '')
      text = decode_entities(text)
      text.gsub(/\r\n/, "\n").gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n").strip
    end

    def decode_entities(text)
      text.gsub(/&(?:[a-z]+|#\d+|#x[0-9a-f]+);/i) do |ent|
        if ENTITY_MAP.key?(ent.downcase)
          ENTITY_MAP[ent.downcase]
        elsif (m = ent.match(/\A&#(\d+);\z/))
          begin
            m[1].to_i.chr(Encoding::UTF_8)
          rescue RangeError
            ent
          end
        elsif (m = ent.match(/\A&#x([0-9a-f]+);\z/i))
          begin
            m[1].to_i(16).chr(Encoding::UTF_8)
          rescue RangeError
            ent
          end
        else
          ent
        end
      end
    end

    # ---- 读取与封装 ---------------------------------------------------------------

    def canonical_json(obj)
      JSON.generate(obj)
    end

    # 读取导出文件，返回 { records:, sources:, format:, parse_errors: }。
    # format ∈ :json_array / :single_object / :jsonl；sources 与 records 一一对应
    # （JSONL 用原始行，数组/对象用 canonical dump），用于 raw 副本与 SHA-256。
    def read_records(path)
      raise ArgumentError, "输入文件不存在: #{path}" unless File.file?(path)

      content = File.read(path, mode: 'r:BOM|UTF-8')
      head = content.lstrip
      if head.start_with?('[')
        arr = JSON.parse(content, **JSON_OPTS)
        raise ArgumentError, '顶层是 JSON 数组但存在非对象元素' unless arr.all? { |r| r.is_a?(Hash) }

        { records: arr, sources: arr.map { |r| canonical_json(r) }, format: :json_array, parse_errors: [] }
      elsif head.start_with?('{')
        begin
          obj = JSON.parse(content, **JSON_OPTS)
          { records: [obj], sources: [canonical_json(obj)], format: :single_object, parse_errors: [] }
        rescue JSON::ParserError
          parse_jsonl(content)
        end
      else
        parse_jsonl(content)
      end
    rescue JSON::ParserError => e
      raise ArgumentError, "JSON 解析失败: #{e.message}"
    end

    def parse_jsonl(content)
      records = []
      sources = []
      parse_errors = []
      content.each_line.with_index(1) do |line, line_no|
        next if line.strip.empty?

        begin
          obj = JSON.parse(line, **JSON_OPTS)
          raise JSON::ParserError, '行不是 JSON 对象' unless obj.is_a?(Hash)

          records << obj
          sources << line.chomp("\n").chomp("\r")
        rescue JSON::ParserError => e
          records << nil
          sources << nil
          parse_errors << { 'line_no' => line_no, 'error' => e.message, 'excerpt' => line.strip[0, 120] }
        end
      end
      { records: records, sources: sources, format: :jsonl, parse_errors: parse_errors }
    end

    # 结合映射的 records_root，把输入展开为「记录数组 + 原始字节来源」
    def records_from_input(path, map)
      payload = read_records(path)
      if payload[:format] == :single_object
        raise ArgumentError, '顶层是对象但映射未声明 records_root；请先用 inspect 探测记录根字段并补全映射' if map.records_root.empty?

        arr = map.records_of(payload[:records].first)
        payload = { records: arr, sources: arr.map { |r| canonical_json(r) }, format: :json_array, parse_errors: payload[:parse_errors] }
      end
      raise ArgumentError, '没有读到任何记录' if payload[:records].empty?

      payload
    end

    # ---- 字段普查（inspect 用）----------------------------------------------------

    def census(records, sample: 20)
      n = sample.to_i
      sampled = n <= 0 ? records : records.first(n)
      stats = {}
      sampled.each do |rec|
        walk_census(rec, '', stats, {}, 0)
      end
      stats.each_value do |st|
        st['rate'] = sampled.empty? ? 0 : (st['count'].to_f / sampled.length).round(4)
        string_samples = st['types'].key?('String') || st['types'].key?('Integer') ? st['samples'].select { |s| s.is_a?(String) } : []
        st['time_like'] = string_samples.any? { |s| s.match?(TIME_HINT_RE) }
        st['url_like'] = string_samples.any? { |s| s.match?(%r{\Ahttps?://}) }
      end
      { 'total_records' => records.length, 'sampled' => sampled.length, 'fields' => stats }
    end

    def walk_census(value, prefix, stats, seen, depth)
      return if depth > 6

      case value
      when Hash
        value.each do |k, v|
          path = prefix.empty? ? k.to_s : "#{prefix}.#{k}"
          record_field!(stats, seen, path, v)
          walk_census(v, path, stats, seen, depth + 1)
        end
      when Array
        value.first(3).each do |el|
          next unless el.is_a?(Hash)

          el.each do |k, v|
            path = "#{prefix}[].#{k}"
            record_field!(stats, seen, path, v)
            walk_census(v, path, stats, seen, depth + 1)
          end
        end
      end
    end

    def record_field!(stats, seen, path, value)
      st = (stats[path] ||= { 'count' => 0, 'types' => {}, 'samples' => [] })
      return if seen[path]

      seen[path] = true
      st['count'] += 1
      type = value.is_a?(Array) ? "Array[#{value_type(value.first)}]" : value_type(value)
      st['types'][type] = (st['types'][type] || 0) + 1
      sample = sample_render(value)
      st['samples'] << sample if sample && st['samples'].size < 3 && !st['samples'].include?(sample)
    end

    def value_type(v)
      v.nil? ? 'nil' : v.class.name
    end

    def sample_render(v)
      case v
      when nil then 'null'
      when String then v.tr("\n", '␤')[0, 60]
      when TrueClass, FalseClass, Numeric then v.to_s
      when Hash then "{#{v.size} keys}"
      when Array then "[#{v.length} 项: #{v.first(2).map { |e| value_type(e) }.join(', ')}]"
      end
    end

    # 顶层包装对象探测：返回 [{path, count}]（候选记录根，按数量降序）
    def probe_record_roots(top)
      candidates = []
      probe = lambda do |obj, path, depth|
        return if depth > 4

        case obj
        when Hash
          obj.each { |k, v| probe.call(v, path.empty? ? k.to_s : "#{path}.#{k}", depth + 1) }
        when Array
          candidates << { 'path' => path, 'count' => obj.length } if obj.first.is_a?(Hash)
        end
      end
      probe.call(top, '', 0)
      candidates.sort_by { |c| [-c['count'], c['path']] }
    end

    def truncate_graphemes(s, n)
      return '' if s.nil?

      g = s.scan(GRAPHHEME_RE)
      g.length <= n ? s : "#{g.first(n).join}…"
    end

    def grapheme_count(s)
      s.to_s.scan(GRAPHHEME_RE).length
    end
  end
end
