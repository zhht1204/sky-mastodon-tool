# frozen_string_literal: true

# 预演/统计报告生成（plan 与 normalize 共用；纯文本渲染，不依赖 Rails）。
require_relative 'normalize'
require_relative 'splitter'
require 'cgi'

module WeiboImport
  module Report
    module_function

    # ---- normalize 汇总 ----

    def normalize_summary(stats)
      <<~TEXT
        == normalize 汇总 ==
        输入格式        : #{stats[:format]}
        读取记录        : #{stats[:read]}
        成功规范化      : #{stats[:ok]}
        错误记录        : #{stats[:errors]}
        错误明细        : #{format_error_breakdown(stats[:error_breakdown])}
        媒体条目        : #{stats[:media_items]}（含 url: #{stats[:media_with_url]}，含本地路径: #{stats[:media_with_path]}）
        原始副本目录    : #{stats[:raw_dir] || '(未启用)'}
        输出            : #{stats[:out]}
        错误清单        : #{stats[:errors_out]}
      TEXT
    end

    def format_error_breakdown(breakdown)
      breakdown.empty? ? '(无)' : breakdown.map { |k, v| "#{k}=#{v}" }.join(', ')
    end

    # ---- inspect 报告 ----

    def inspect_report(census, roots: [])
      lines = []
      lines << '# 字段映射报告（inspect 生成草稿）'
      lines << ''
      lines << "> 由 `weibo_normalize.rb inspect` 自动生成；**这只是草稿**，必须逐字段人工核对后"
      lines << '> 填入 `config/field_map.yml`（流程与填法见 docs/field-mapping-report.md）。'
      lines << '> 报告中的样例已做 HTML 转义；inspect/normalize 绝不执行 JSON 内的任何代码或脚本。'
      lines << ''
      lines << "总记录数: #{census['total_records']}，普查抽样: #{census['sampled']}"
      unless roots.empty?
        lines << ''
        lines << '## 候选记录根（顶层是包装对象时，把最大数组路径填入 records_root）'
        roots.first(5).each { |r| lines << "- `#{r['path']}`（#{r['count']} 条）" }
      end
      lines << ''
      lines << '## 字段普查（出现率 = 含该字段的抽样记录占比）'
      lines << ''
      lines << '| 字段路径 | 出现率 | 类型分布 | 时间样例 | URL 样例 | 值样例 |'
      lines << '|---|---|---|---|---|---|'
      census['fields'].sort_by { |path, _| [path.count('[]'), path] }.each do |path, st|
        types = st['types'].map { |t, n| "#{t}×#{n}" }.join(', ')
        time_s = st['time_like'] ? '✓' : ''
        url_s = st['url_like'] ? '✓' : ''
        samples = st['samples'].map { |s| CGI.escapeHTML(s.to_s) }.join('<br>')
        lines << "| `#{path}` | #{(st['rate'] * 100).round(1)}% | #{CGI.escapeHTML(types)} | #{time_s} | #{url_s} | #{samples} |"
      end
      lines << ''
      lines << '## 下一步'
      lines << ''
      lines << '1. 按上表确定 `id` / `created_at` / `text` / 媒体 / 回复 / 转发 / 可见性字段（不预设字段名，一切以普查为准）。'
      lines << '2. 复制 `config/field_map.example.yml` 为草稿并填写，经 `weibo_normalize.rb map --from 草稿.yml` 校验安装。'
      lines << '3. 跑 `normalize`（先小样本）并核对 errors.jsonl；任何异常时间/字段都必须人工复核，不得静默修正。'
      lines.join("\n") + "\n"
    end

    # ---- plan 预演报告 ----

    # records: normalized 记录数组；返回 stats hash（数字均为精确值）
    def plan_stats(records, limit: nil, splitter_params: {})
      records = records.first(limit) if limit && limit.positive?

      stats = {
        'total' => 0, 'duplicates' => 0, 'earliest' => nil, 'latest' => nil,
        'originals' => 0, 'reposts' => 0, 'replies' => 0, 'non_public' => 0,
        'overlong' => 0, 'media_images' => 0, 'media_videos' => 0,
        'media_missing' => 0, 'media_pending_fetch' => 0, 'media_ready' => 0,
        'projected_statuses' => 0, 'anomalies' => []
      }
      seen = Hash.new(0)

      records.each_with_index do |rec, idx|
        sid = rec['source_id'].to_s
        if sid.empty?
          add_anomaly(stats, idx, nil, '缺少 source_id', '跳过该条并人工复核（normalize 不应产出此类记录）')
          next
        end
        seen[sid] += 1
        stats['total'] += 1

        begin
          t = Time.iso8601(rec['created_at'].to_s)
          stats['earliest'] = t if stats['earliest'].nil? || t < stats['earliest']
          stats['latest'] = t if stats['latest'].nil? || t > stats['latest']
        rescue ArgumentError
          add_anomaly(stats, idx, sid, "created_at 无法解析: #{rec['created_at'].inspect}", '跳过该条并人工复核')
        end

        stats['reposts'] += 1 unless rec['repost'].nil?
        stats['replies'] += 1 unless rec['reply_to_source_id'].to_s.empty?
        stats['originals'] += 1 if rec['repost'].nil? && rec['reply_to_source_id'].to_s.empty?
        stats['non_public'] += 1 unless rec['visibility'] == 'public'

        media = Array(rec['media'])
        media.each do |m|
          next unless m.is_a?(Hash)

          url = m['url'].to_s.strip
          path = m['path'].to_s.strip
          if Splitter.video?(m)
            stats['media_videos'] += 1
          else
            stats['media_images'] += 1
          end
          if url.empty? && path.empty?
            stats['media_missing'] += 1
          elsif !path.empty? && File.exist?(path)
            stats['media_ready'] += 1
          elsif !url.empty?
            stats['media_pending_fetch'] += 1
          else
            stats['media_missing'] += 1 # 有 path 但文件不存在且无 url，无法获得
          end
        end

        segs = Splitter.segments(rec, **splitter_params)
        stats['projected_statuses'] += segs.length
        if segs.length > 1 || Splitter.weighted_length(rec['text'].to_s, url_weight: splitter_params.fetch(:url_weight, Splitter::URL_WEIGHT)) > splitter_params.fetch(:max_chars, Splitter::DEFAULT_MAX_CHARS)
          stats['overlong'] += 1
        end
        if segs.length > 1 && rec['repost']
          add_anomaly(stats, idx, sid, '转发内容超长被拆分', '按拆分导入（转发=文字引用，见红线）')
        end
      end

      stats['duplicates'] = seen.count { |_, n| n > 1 }
      seen.each do |sid, n|
        add_anomaly(stats, nil, sid, "重复 source_id（#{n} 次）", '保留首条，其余跳过重复（账本唯一约束兜底）') if n > 1
      end
      stats
    end

    def add_anomaly(stats, index, source_id, reason, strategy)
      stats['anomalies'] << { 'index' => index, 'source_id' => source_id, 'reason' => reason, 'strategy' => strategy }
    end

    def plan_report(stats, account:, visibility:, limit:, batch:)
      fmt_time = ->(t) { t.nil? ? '(无)' : t.iso8601 }
      lines = []
      lines << '# weibo-import 预演报告（plan）'
      lines << ''
      lines << "目标账号: #{account}  |  目标可见性: #{visibility}（只能收紧不能放宽）  |  批次: #{batch}  |  限额: #{limit ? "前 #{limit} 条来源微博" : '全部'}"
      lines << ''
      lines << '## 数字总览'
      lines << ''
      lines << "| 指标 | 值 |"
      lines << "|---|---|"
      { '来源微博总数' => stats['total'],
        '重复 source_id 数' => stats['duplicates'],
        '最早时间' => fmt_time.call(stats['earliest']),
        '最晚时间' => fmt_time.call(stats['latest']),
        '原创数' => stats['originals'],
        '转发数' => stats['reposts'],
        '回复数' => stats['replies'],
        '非公开（<public）数' => stats['non_public'],
        '超长正文数（>500 加权）' => stats['overlong'],
        '图片数' => stats['media_images'],
        '视频数' => stats['media_videos'],
        '缺失媒体数（无法获得）' => stats['media_missing'],
        '待下载媒体数（有 URL 无本地文件）' => stats['media_pending_fetch'],
        '本地就绪媒体数' => stats['media_ready'],
        '拆分后预计创建帖子数' => stats['projected_statuses'] }.each do |k, v|
        lines << "| #{k} | #{v} |"
      end
      lines << ''
      lines << "计数口径说明：--limit 语义 = 截取前 N 条**来源微博**（非拆分后帖子数）；"
      lines << '超长/拆分按 splitter 精确计算（URL 加权 23、字素簇计数、媒体 4 图/帖、视频单独成帖）。'
      lines << ''
      lines << '## 异常记录清单及拟处理策略'
      lines << ''
      if stats['anomalies'].empty?
        lines << '（无异常）'
      else
        lines << '| # | source_id | 异常 | 拟处理策略 |'
        lines << '|---|---|---|---|'
        stats['anomalies'].each_with_index do |a, i|
          lines << "| #{a['index'] || '-'} | #{a['source_id'] || '-'} | #{CGI.escapeHTML(a['reason'])} | #{CGI.escapeHTML(a['strategy'])} |"
        end
      end
      lines << ''
      lines << '> plan 是只读预演。确认导入前必须完成：env-check（实例实测）→ 备份 → 试导入 20 条验收（批次 B）。'
      lines.join("\n") + "\n"
    end

    def fetch_summary(stats)
      <<~TEXT
        == fetch-media 汇总 ==
        媒体条目        : #{stats[:total]}
        本地就绪跳过    : #{stats[:skipped_local]}
        下载成功        : #{stats[:ok]}
        下载失败        : #{stats[:failed]}（重试后仍失败，见 missing-media.jsonl）
        无法获得        : #{stats[:no_url]}（无 URL 且无本地文件，见 missing-media.jsonl）
        扩展名不符警告  : #{stats[:extension_mismatch]}
        结果清单        : #{stats[:results_out]}
        缺失清单        : #{stats[:missing_out]}
      TEXT
    end
  end
end
