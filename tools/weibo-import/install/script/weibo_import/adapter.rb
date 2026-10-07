# frozen_string_literal: true

# 声明式字段映射适配器：映射表（config/field_map.yml）是唯一事实来源，
# 不预设任何导出工具的字段名。必须先用 `weibo_normalize.rb inspect` 对真实样本
# 做字段普查，再人工确认映射；禁止凭假设写字段名。
require 'yaml'

module WeiboImport
  module Adapter
    class MapError < StandardError; end

    VISIBILITY_RANK = { 'public' => 0, 'unlisted' => 1, 'private' => 2, 'direct' => 3 }.freeze
    ALLOWED_VISIBILITIES = VISIBILITY_RANK.keys.freeze
    # 与 Normalize::TZ_ALIASES 同名的内置别名白名单（大写）；最终偏移映射在 Normalize.resolve_tz 校验
    TZ_ALIAS_NAMES = %w[
      UTC GMT ASIA/SHANGHAI ASIA/CHONGQING ASIA/HARBIN ASIA/TAIPEI ASIA/HONG_KONG
      ASIA/MACAU ASIA/SINGAPORE ASIA/TOKYO ASIA/SEOUL EUROPE/LONDON
    ].freeze

    # 内嵌示例模板（weibo_normalize.rb map --print-example 输出同款）
    EXAMPLE_MAP = <<~YAML
      source: weibo
      records_root: ""            # 顶层是包装对象时记录数组的点路径
      id:
        field: ""                 # 必填：ID 字段；值全程按字符串处理
      created_at:
        field: ""                 # 必填：时间字段（ISO8601/常见格式/epoch s|ms）
        timezone: "Asia/Shanghai" # 仅当时间无时区/偏移时使用
      text:
        field: ""                 # 必填：正文字段
        html: false               # true = 含 HTML（只做 HTML→纯文本，绝不执行脚本）
      source_url:
        field: ""                 # 可选：原文链接字段
      visibility:
        field: ""                 # 可选：可见性字段
        default: unlisted
        mapping: {}               # 来源值 -> public/unlisted/private/direct
        strictness: {}            # 来源值 -> 0..3；映射目标 rank 必须 >= 该值（不放宽）
      reply:
        field: ""                 # 可选：回复目标 ID 字段
      repost:
        field: ""                 # 可选：转发标记字段
        truthy: [true, 1, "true", "1"]
        quote_field: ""           # 可选：被转发原文摘要字段
      media:
        list_field: ""            # 可选：媒体数组字段
        url_field: "url"
        path_field: "local_path"
        description_field: "alt"
    YAML

    module_function

    # 点路径取值："a.b.c"；数组段支持数字下标 "items.0.url"。未命中返回 nil。
    def dig(record, path)
      return nil if path.nil? || path.to_s.strip.empty?
      cur = record
      path.to_s.split('.').each do |seg|
        return nil if cur.nil?
        if cur.is_a?(Array)
          return nil unless seg =~ /\A\d+\z/

          cur = cur[seg.to_i]
        elsif cur.is_a?(Hash)
          cur = cur[seg]
        else
          return nil
        end
      end
      cur
    end

    def deep_stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
      when Array then obj.map { |v| deep_stringify(v) }
      else obj
      end
    end

    # 中间形态：只做提取，不做时间解析/文本清洗（那是 normalize 的职责）
    Extracted = Struct.new(
      :source_id, :created_at_raw, :text_raw, :text_html, :source_url,
      :visibility_raw, :reply_to_raw, :repost_raw, :repost_quote_raw,
      :media_items, :media_error, :retweet_media_items,
      :interactions, :comments_raw, :card_title, :card_link, keyword_init: true
    )

    class Map
      attr_reader :config, :source, :records_root

      def self.load(path)
        raise MapError, "映射文件不存在: #{path}" unless File.file?(path)

        data = YAML.safe_load(File.read(path, mode: 'r:BOM|UTF-8'), aliases: false)
        raise MapError, "映射文件顶层不是 YAML 对象: #{path}" unless data.is_a?(Hash)

        from_hash(Adapter.deep_stringify(data))
      rescue Psych::SyntaxError => e
        raise MapError, "映射文件 YAML 解析失败: #{e.message}"
      end

      def self.from_hash(data)
        new(Adapter.deep_stringify(data)).tap(&:validate!)
      end

      def initialize(config)
        @config = config
        @source = @config['source'].to_s.strip
        @records_root = @config['records_root'].to_s.strip
        %w[id created_at text source_url visibility reply repost media interactions card].each { |k| @config[k] ||= {} }
      end

      def validate!
        errors = []
        errors << 'source 必填（微博归档固定为 weibo）' if @source.empty?
        errors << 'id.field 必填' if cfg('id', 'field').to_s.strip.empty?
        errors << 'created_at.field 必填' if cfg('created_at', 'field').to_s.strip.empty?
        errors << 'text.field 必填' if cfg('text', 'field').to_s.strip.empty?

        tz = cfg('created_at', 'timezone')
        unless tz.nil? || tz.to_s.strip.empty? || tz.to_s =~ /\A[+-]\d{2}:?\d{2}\z/ || TZ_ALIAS_NAMES.include?(tz.to_s.strip.upcase)
          errors << "created_at.timezone 非法: #{tz.inspect}（用固定偏移 ±HH:MM 或 Asia/Shanghai 等内置别名，别名在 normalize 阶段最终校验）"
        end

        vis = @config['visibility']
        default = vis['default'].to_s
        if !default.empty? && !ALLOWED_VISIBILITIES.include?(default)
          errors << "visibility.default 非法: #{default}（允许 #{ALLOWED_VISIBILITIES.join('/')}"
        end
        mapping = vis['mapping'] || {}
        strictness = vis['strictness'] || {}
        errors << 'visibility.mapping 必须是对象' unless mapping.is_a?(Hash)
        errors << 'visibility.strictness 必须是对象' unless strictness.is_a?(Hash)
        mapping.each do |k, v|
          unless ALLOWED_VISIBILITIES.include?(v.to_s)
            errors << "visibility.mapping[#{k.inspect}] 非法目标: #{v}"
            next
          end
          need = strictness[k]
          if !need.nil? && !(need.is_a?(Integer) && (0..3).cover?(need))
            errors << "visibility.strictness[#{k.inspect}] 必须是 0..3 整数"
            next
          end
          src_rank = need.nil? ? VISIBILITY_RANK[v.to_s] : need
          errors << "visibility.mapping[#{k.inspect}] 放宽了可见性: #{k} -> #{v}（strictness=#{src_rank}）" if VISIBILITY_RANK[v.to_s] < src_rank
        end

        raise MapError, "字段映射校验失败:\n  - #{errors.join("\n  - ")}" unless errors.empty?
        self
      end

      def id_field = cfg('id', 'field').to_s
      def created_at_field = cfg('created_at', 'field').to_s
      def text_field = cfg('text', 'field').to_s
      def text_html? = truthy?(cfg('text', 'html'))
      def source_url_field = cfg('source_url', 'field').to_s
      def source_url_template = cfg('source_url', 'template').to_s
      def visibility_field = cfg('visibility', 'field').to_s
      def visibility_cfg = @config['visibility']
      def reply_field = cfg('reply', 'field').to_s
      def repost_field = cfg('repost', 'field').to_s
      def repost_truthy = Array(@config.dig('repost', 'truthy')).empty? ? [true, 1, 'true', '1'] : Array(@config.dig('repost', 'truthy'))
      def repost_quote_field = cfg('repost', 'quote_field').to_s
      def repost_quote_template = cfg('repost', 'quote_template').to_s
      def repost_quote_max
        v = cfg('repost', 'quote_max')
        v.to_s.strip.empty? ? 200 : v.to_i
      end
      def media_list_field = cfg('media', 'list_field').to_s
      def media_retweet_list_field = cfg('media', 'retweet_list_field').to_s

      def media_cfg
        { 'url' => cfg('media', 'url_field').to_s,
          'path' => cfg('media', 'path_field').to_s,
          'description' => cfg('media', 'description_field').to_s }
      end

      def interactions_cfg
        %w[reposts comments_count likes comments].to_h { |k| [k, cfg('interactions', k).to_s] }
      end

      def card_cfg
        { 'title' => cfg('card', 'title').to_s,
          'link' => cfg('card', 'link').to_s }
      end

      def timezone = cfg('created_at', 'timezone').to_s.strip

      # 顶层包装对象的记录根：records_root 非空时从对象中取数组
      def records_of(top_object)
        return [top_object] if records_root.empty?
        arr = Adapter.dig(top_object, records_root)
        raise MapError, "records_root #{records_root.inspect} 未命中数组" unless arr.is_a?(Array)
        arr
      end

      def extract(record)
        media_items, media_error = extract_media(record, media_list_field)
        retweet_media, retweet_media_error = extract_media(record, media_retweet_list_field)
        repost_raw = present_value(Adapter.dig(record, repost_field))
        source_url = present_string(Adapter.dig(record, source_url_field))
        source_url = present_string(interpolate(source_url_template, record)) if source_url.nil? && !source_url_template.empty?
        quote_raw = if repost_flag(repost_raw) && !repost_quote_template.empty?
                      present_value(interpolate(repost_quote_template, record))
                    elsif repost_flag(repost_raw)
                      present_value(Adapter.dig(record, repost_quote_field))
                    end
        icfg = interactions_cfg
        ccfg = card_cfg
        Extracted.new(
          source_id: present_string(Adapter.dig(record, id_field)),
          created_at_raw: present_value(Adapter.dig(record, created_at_field)),
          text_raw: present_value(Adapter.dig(record, text_field)),
          text_html: text_html?,
          source_url: source_url,
          visibility_raw: present_value(Adapter.dig(record, visibility_field)),
          reply_to_raw: present_value(Adapter.dig(record, reply_field)),
          repost_raw: repost_raw,
          repost_quote_raw: quote_raw,
          media_items: media_items,
          media_error: media_error || retweet_media_error,
          retweet_media_items: retweet_media,
          interactions: {
            'reposts' => count_of(record, icfg['reposts']),
            'comments_count' => count_of(record, icfg['comments_count']),
            'likes' => count_of(record, icfg['likes'])
          },
          comments_raw: list_of(record, icfg['comments']),
          card_title: present_string(Adapter.dig(record, ccfg['title'])),
          card_link: present_string(Adapter.dig(record, ccfg['link']))
        )
      end

      # 转发判定的唯一实现：normalize 委托此处，避免两份逻辑漂移
      def repost_flag(raw)
        return false if raw.nil?
        return !raw.empty? if raw.is_a?(Hash) || raw.is_a?(Array)

        truthy = repost_truthy
        truthy.include?(raw) || truthy.include?(raw.to_s)
      end

      private

      # 模板插值：{dot.path} 从记录取值；路径缺失/为空时整个占位符替换为空串
      def interpolate(template, record)
        template.to_s.gsub(/\{([\w.]+)\}/) do
          v = Adapter.dig(record, Regexp.last_match(1))
          v.nil? || (v.is_a?(String) && v.strip.empty?) ? '' : v.to_s
        end
      end

      def cfg(section, key)
        @config.dig(section, key)
      end

      def extract_media(record, list_field)
        return [[], nil] if list_field.to_s.empty?

        list = Adapter.dig(record, list_field)
        return [[], nil] if list.nil?
        return [nil, "媒体字段 #{list_field} 不是数组: #{list.class}"] unless list.is_a?(Array)

        names = media_cfg
        items = list.map do |item|
          if item.is_a?(Hash)
            {
              'url' => present_string(Adapter.dig(item, names['url'])),
              'path' => present_string(Adapter.dig(item, names['path'])),
              'description' => present_string(Adapter.dig(item, names['description']))
            }
          else
            { 'url' => present_string(item), 'path' => nil, 'description' => nil }
          end
        end
        [items, nil]
      end

      def present_value(v)
        return nil if v.is_a?(String) && v.strip.empty?
        v
      end

      def count_of(record, field)
        return nil if field.to_s.empty?

        v = Adapter.dig(record, field)
        return nil if v.nil?
        return nil if v.is_a?(String) && v.strip.empty?

        v.to_i
      end

      def list_of(record, field)
        return nil if field.to_s.empty?

        v = Adapter.dig(record, field)
        return nil if v.nil?
        return nil unless v.is_a?(Array)

        v
      end

      def present_string(v)
        s = present_value(v)
        s.nil? ? nil : s.to_s
      end

      def truthy?(v)
        v == true || v == 1 || v.to_s.downcase == 'true'
      end
    end
  end
end
