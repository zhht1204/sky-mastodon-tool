# frozen_string_literal: true

# 纯逻辑：正文拆分 + >4 图分组（plan 与 import 共用，绝不触碰 Rails/DB）。
#
# 规则（批次 A 固化，批次 B 可按部署实例校准常量）：
# - 字符计数：URL 按固定权重（默认 23，Mastodon 对链接的加权计数），
#   其余按字素簇（\X）计数；所有正文（含任何编号标记）都计入长度。
# - 拆分边界优先级：段落（\n\n）→ 句子（。！？!?…；; 与换行）→ 硬切（绝不切断 URL）。
# - 不自动添加任何编号/前缀文字（不伪造内容）；拆分点上的段落空行会被吞掉（以续帖边界表达）。
# - >4 张图按原顺序分组挂同一串；首组随首段，其余各组各成一帖（纯媒体续帖，正文为空）；
#   视频按 Mastodon 约束单独成帖（1 视频/帖）。不丢图、不改顺序。
# - 每段（含媒体续帖）继承同一 created_at；父段在前、子段在后，段间 reply 关系。
module WeiboImport
  module Splitter
    DEFAULT_MAX_CHARS = 500 # Mastodon 默认 toot 字符上限；批次 B 须按部署实例配置校准
    URL_WEIGHT = 23         # Mastodon 链接加权计数；批次 B 须按部署版本校准
    MEDIA_PER_POST = 4      # Mastodon 默认每帖最多 4 图；视频 1 条/帖
    URL_RE = %r{https?://[^\s<>"'）】]+}i.freeze
    VIDEO_EXTS = %w[.mp4 .webm .mov .m4v .mkv].freeze

    module_function

    # 加权长度：URL 原子计数 URL_WEIGHT，其余按字素簇
    def weighted_length(text, url_weight: URL_WEIGHT)
      return 0 if text.nil? || text.empty?

      total = 0
      pos = 0
      while (m = URL_RE.match(text, pos))
        total += WeiboImport::Normalize.grapheme_count(text[pos...m.begin(0)])
        total += url_weight
        pos = m.end(0)
      end
      total + WeiboImport::Normalize.grapheme_count(text[pos..])
    end

    # 原子切分：URL 与连续非 URL 字素各自为原子（保证绝不把 URL 切成两半）
    def tokenize(text)
      tokens = []
      pos = 0
      while (m = URL_RE.match(text, pos))
        tokens << { kind: :text, str: text[pos...m.begin(0)] } if m.begin(0) > pos
        tokens << { kind: :url, str: m[0] }
        pos = m.end(0)
      end
      tokens << { kind: :text, str: text[pos..] } if pos < text.length
      tokens
    end

    def token_weight(tok, url_weight: URL_WEIGHT)
      tok[:kind] == :url ? url_weight : WeiboImport::Normalize.grapheme_count(tok[:str])
    end

    # 正文拆分：返回数组，每个元素 { text:, overlong: bool }，weighted ≤ max_chars
    # （单个原子自身超限时独立成段并标记 overlong，绝不丢内容）
    def split_text(text, max_chars: DEFAULT_MAX_CHARS, url_weight: URL_WEIGHT)
      return [] if text.nil? || text.strip.empty?

      segments = []
      paragraphs = text.strip.split(/\n{2,}+/)
      cur = +''
      cur_weight = 0

      paragraphs.each do |para|
        sentences = para.split(/(?<=[。！？!?…；;\n])/).reject(&:empty?)
        pieces = []
        sentences.each do |sentence|
          tokenize(sentence).each { |t| pieces << t }
        end

        pieces.each_with_index do |piece, _i|
          pw = token_weight(piece, url_weight: url_weight)
          next if pw.zero? && piece[:kind] == :text

          # 段落边界由分段本身表达：跨段落拼进同一段时不加分隔符（段落空行被吞，见文件头注释）
          cand_weight = cur_weight + pw
          if cur.empty?
            if pw > max_chars
              # 单个原子超限（超长 URL / 无边界巨句）：硬切文本原子；URL 原子独立成段
              segments.concat(emit_piece(piece, max_chars, url_weight))
              cur = +''
              cur_weight = 0
            else
              cur = piece[:str].dup
              cur_weight = pw
            end
          elsif cand_weight <= max_chars
            cur << piece[:str]
            cur_weight = cand_weight
          else
            segments << { 'text' => cur, 'overlong' => false }
            if pw > max_chars
              segments.concat(emit_piece(piece, max_chars, url_weight))
              cur = +''
              cur_weight = 0
            else
              cur = piece[:str].dup
              cur_weight = pw
            end
          end
        end
      end
      segments << { 'text' => cur, 'overlong' => false } unless cur.empty?
      segments
    end

    # 超限单原子处理：文本按字素硬切；URL 独立成段并标记 overlong。恒返回数组。
    def emit_piece(piece, max_chars, _url_weight)
      if piece[:kind] == :url
        [{ 'text' => piece[:str], 'overlong' => true }]
      else
        graphemes = piece[:str].scan(/\X/)
        chunks = graphemes.each_slice(max_chars).map(&:join)
        chunks.map { |c| { 'text' => c, 'overlong' => false } }
      end
    end

    # 完整分段：输入规范化记录，输出段数组（有序，父段在前）
    # 每段: { segment_no:, text:, media:, created_at:, parent_segment_no: }
    def segments(record, max_chars: DEFAULT_MAX_CHARS, url_weight: URL_WEIGHT, media_per_post: MEDIA_PER_POST)
      text = record['text'].to_s
      text_segments = split_text(text, max_chars: max_chars, url_weight: url_weight)

      units = media_units(Array(record['media']), media_per_post)

      out = []
      if text_segments.empty?
        units.each do |unit|
          out << { 'text' => '', 'media' => unit }
        end
        out << { 'text' => '', 'media' => [] } if out.empty? # 空帖保底（导入批次 B 决定是否跳过）
      else
        head_media = units.shift || []
        text_segments.each_with_index do |seg, i|
          out << { 'text' => seg['text'], 'media' => i.zero? ? head_media : [] }
        end
        units.each { |unit| out << { 'text' => '', 'media' => unit } }
      end

      created_at = record['created_at']
      out.each_with_index.map do |seg, i|
        {
          'segment_no' => i,
          'text' => seg['text'],
          'media' => seg['media'],
          'created_at' => created_at,
          'parent_segment_no' => i.zero? ? nil : i - 1
        }
      end
    end

    # 媒体分组：保序遍历，图片按 media_per_post 分组、视频单独成组、
    # 无 url 无 path 的无效项被剔除（由调用方计为缺失媒体）
    def media_units(media, media_per_post = MEDIA_PER_POST)
      units = []
      current = []
      media.each do |m|
        next unless m.is_a?(Hash) && (m['url'].to_s.strip != '' || m['path'].to_s.strip != '')

        if video?(m)
          units << current unless current.empty?
          current = []
          units << [m]
        else
          current << m
          if current.length >= media_per_post
            units << current
            current = []
          end
        end
      end
      units << current unless current.empty?
      units
    end

    def video?(media)
      name = (media['path'].to_s.empty? ? media['url'].to_s : media['path'].to_s)
      ext = File.extname(name.to_s.split('?').first.to_s.downcase)
      VIDEO_EXTS.include?(ext)
    end
  end
end
