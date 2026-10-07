#!/usr/bin/env ruby
# frozen_string_literal: true

# weibo_normalize.rb — 独立 CLI（纯 Ruby，不依赖 Rails）: inspect | map | normalize | fetch-media
#
# 流程红线：
#   inspect → 字段普查（绝不执行 JSON 内任何代码/脚本/HTML；HTML 字段只做转义与统计）
#   map     → 人工确认映射后校验并安装 config/field_map.yml（真实映射 gitignore）
#   normalize → JSON → normalized.jsonl（source_id 全程字符串；时间保真；错误进 errors.jsonl）
#   fetch-media → SSRF 安全下载；缺失媒体显式写 missing-media.jsonl
require 'optparse'
require 'fileutils'
require 'json'
require_relative 'weibo_import/adapter'
require_relative 'weibo_import/normalize'
require_relative 'weibo_import/downloader'
require_relative 'weibo_import/report'

module WeiboNormalizeCLI
  VALID = %w[inspect map normalize fetch-media].freeze

  module_function

  def run(argv)
    sub = argv.shift
    case sub
    when 'inspect' then run_inspect(argv)
    when 'map' then run_map(argv)
    when 'normalize' then run_normalize(argv)
    when 'fetch-media' then run_fetch_media(argv)
    when nil then usage('缺少子命令')
    else usage("未知子命令: #{sub}")
    end
  rescue OptionParser::ParseError, ArgumentError => e
    warn "错误: #{e.message}"
    1
  end

  def usage(msg = nil)
    warn msg if msg
    warn '用法: weibo_normalize.rb <inspect|map|normalize|fetch-media> [options]（各子命令加 --help 看详细）'
    msg ? 64 : 0
  end

  def run_inspect(argv)
    opts = { input: nil, sample: 20, report_out: 'docs/field-mapping-report.generated.md' }
    OptionParser.new do |o|
      o.banner = '用法: weibo_normalize.rb inspect --input <导出.json> [--sample N] [--report-out PATH]'
      o.on('--input PATH', '导出 JSON/JSONL 文件（必填）') { |v| opts[:input] = v }
      o.on('--sample N', Integer, '普查抽样记录数（默认 20；0=全部）') { |v| opts[:sample] = v }
      o.on('--report-out PATH', "报告草稿输出路径（默认 #{opts[:report_out]}）") { |v| opts[:report_out] = v }
    end.parse(argv)
    raise ArgumentError, 'inspect 需要 --input' if opts[:input].to_s.strip.empty?

    payload = WeiboImport::Normalize.read_records(opts[:input])
    records = payload[:records]
    roots = []
    if payload[:format] == :single_object
      roots = WeiboImport::Normalize.probe_record_roots(records.first)
      best = roots.first
      if best
        arr = WeiboImport::Adapter.dig(records.first, best['path'])
        records = arr if arr.is_a?(Array)
      end
    end
    census = WeiboImport::Normalize.census(records, sample: opts[:sample])
    report = WeiboImport::Report.inspect_report(census, roots: roots)
    $stdout.puts report
    unless opts[:report_out].to_s.strip.empty?
      dir = File.dirname(File.expand_path(opts[:report_out]))
      FileUtils.mkdir_p(dir)
      File.write(opts[:report_out], report)
      warn "报告草稿已写入 #{opts[:report_out]}"
    end
    if payload[:parse_errors] && !payload[:parse_errors].empty?
      warn "警告: #{payload[:parse_errors].length} 行解析失败（已跳过，请人工检查输入文件）"
    end
    0
  end

  def run_map(argv)
    opts = { from: nil, out: 'config/field_map.yml', print_example: false }
    OptionParser.new do |o|
      o.banner = '用法: weibo_normalize.rb map [--from 草稿.yml] [--out PATH] [--print-example]'
      o.on('--from PATH', '人工确认后的映射草稿（必填，除非 --print-example）') { |v| opts[:from] = v }
      o.on('--out PATH', "安装目标（默认 #{opts[:out]}；该文件已 gitignore）") { |v| opts[:out] = v }
      o.on('--print-example', '打印示例映射模板') { opts[:print_example] = true }
    end.parse(argv)

    if opts[:print_example]
      puts WeiboImport::Adapter::EXAMPLE_MAP
      return 0
    end
    raise ArgumentError, 'map 需要 --from <人工确认后的映射草稿>（先跑 inspect，禁止凭假设写字段名）' if opts[:from].nil?

    map = WeiboImport::Adapter::Map.load(opts[:from]) # 校验失败会抛 MapError
    dir = File.dirname(File.expand_path(opts[:out]))
    FileUtils.mkdir_p(dir)
    File.write(opts[:out], File.read(opts[:from]))
    puts "映射校验通过并已安装: #{opts[:out]}"
    puts "  source=#{map.source}  id=#{map.id_field}  created_at=#{map.created_at_field}(tz=#{map.timezone})  text=#{map.text_field}(html=#{map.text_html?})"
    puts "  media=#{map.media_list_field.empty? ? '(无)' : map.media_list_field}  reply=#{map.reply_field.empty? ? '(无)' : map.reply_field}  repost=#{map.repost_field.empty? ? '(无)' : map.repost_field}  records_root=#{map.records_root.empty? ? '(顶层即记录)' : map.records_root}"
    0
  rescue WeiboImport::Adapter::MapError => e
    warn "映射校验失败:\n#{e.message}"
    1
  end

  def run_normalize(argv)
    opts = {
      input: nil, map: 'config/field_map.yml', out: 'normalized.jsonl',
      raw_dir: nil, errors_out: 'errors.jsonl', default_tz: 'Asia/Shanghai',
      interactions: 'summary', retweet_media: 'include', card: 'ignore'
    }
    OptionParser.new do |o|
      o.banner = '用法: weibo_normalize.rb normalize --input X --map config/field_map.yml --out normalized.jsonl [--raw-dir raw_copy/] [--default-tz Asia/Shanghai] [--errors-out errors.jsonl] [--interactions summary|metadata|counts] [--retweet-media include|skip] [--card ignore|append]'
      o.on('--input PATH', '导出 JSON/JSONL（必填）') { |v| opts[:input] = v }
      o.on('--map PATH', "字段映射（默认 #{opts[:map]}）") { |v| opts[:map] = v }
      o.on('--out PATH', "输出 JSONL（默认 #{opts[:out]}）") { |v| opts[:out] = v }
      o.on('--raw-dir DIR', '原始记录只读副本目录（每条一个文件 + SHA-256）') { |v| opts[:raw_dir] = v }
      o.on('--default-tz TZ', '时间无时区时的默认时区（默认 Asia/Shanghai；可用 +08:00）') { |v| opts[:default_tz] = v }
      o.on('--errors-out PATH', "错误清单输出（默认 #{opts[:errors_out]}）") { |v| opts[:errors_out] = v }
      o.on('--interactions MODE', %w[summary metadata counts],
           '互动数据呈现：summary=正文尾部计数行+评论入元数据（默认）；metadata=全部仅入元数据；counts=仅保留计数，评论丢弃') { |v| opts[:interactions] = v }
      o.on('--retweet-media MODE', %w[include skip],
           '转发原文图片：include=按原顺序挂载导入（默认）；skip=仅文字引用') { |v| opts[:retweet_media] = v }
      o.on('--card MODE', %w[ignore append],
           '卡片：ignore=忽略（默认）；append=卡片标题+链接追加正文') { |v| opts[:card] = v }
    end.parse(argv)
    raise ArgumentError, 'normalize 需要 --input' if opts[:input].to_s.strip.empty?

    policy = WeiboImport::Normalize.validate_policy!(
      'interactions' => opts[:interactions], 'retweet_media' => opts[:retweet_media], 'card' => opts[:card]
    )

    map = WeiboImport::Adapter::Map.load(opts[:map])
    default_offset = WeiboImport::Normalize.resolve_tz(opts[:default_tz])
    map_tz = map.timezone
    map_tz_offset = map_tz.empty? ? default_offset : WeiboImport::Normalize.resolve_tz(map_tz)

    payload = WeiboImport::Normalize.records_from_input(opts[:input], map)
    records = payload[:records]
    sources = payload[:sources]

    FileUtils.mkdir_p(File.dirname(File.expand_path(opts[:out])))
    out_f = File.open(opts[:out], 'w:UTF-8')
    err_f = File.open(opts[:errors_out], 'w:UTF-8')
    stats = { format: payload[:format], read: 0, ok: 0, errors: 0, error_breakdown: Hash.new(0),
              media_items: 0, media_with_url: 0, media_with_path: 0, raw_dir: opts[:raw_dir], out: opts[:out], errors_out: opts[:errors_out] }

    records.each_with_index do |rec, idx|
      stats[:read] += 1
      if rec.nil?
        pe = payload[:parse_errors][idx] || {}
        err_f.puts(JSON.generate({ 'record_index' => idx, 'line_no' => pe['line_no'], 'source_id' => nil, 'reason' => "JSON 解析失败: #{pe['error']}" }))
        stats[:errors] += 1
        stats[:error_breakdown]['json_parse_error'] += 1
        next
      end

      normalized =
        begin
          WeiboImport::Normalize.normalize_record(rec, map, index: idx, original_line: sources[idx], default_offset: map_tz_offset, policy: policy)
        rescue WeiboImport::Normalize::RecordError => e
          err_f.puts(JSON.generate({ 'record_index' => idx, 'source_id' => (map.extract(rec).source_id rescue nil), 'reason' => e.message }))
          stats[:errors] += 1
          stats[:error_breakdown][e.message.sub(/:.*\z/, '')] += 1
          nil
        end

      if normalized.nil?
        write_raw_copy(opts[:raw_dir], idx, sources[idx])
        next
      end

      out_f.puts(JSON.generate(normalized))
      stats[:ok] += 1
      media = normalized['media'] || []
      stats[:media_items] += media.length
      stats[:media_with_url] += media.count { |m| m['url'].to_s.strip != '' }
      stats[:media_with_path] += media.count { |m| m['path'].to_s.strip != '' }
      write_raw_copy(opts[:raw_dir], idx, sources[idx])
    end
    out_f.close
    err_f.close

    stats[:policy] = policy
    puts WeiboImport::Report.normalize_summary(stats)
    warn "错误 #{stats[:errors]} 条已写入 #{opts[:errors_out]}；绝不用当前时间顶替，必须人工复核。" if stats[:errors].positive?
    0
  end

  def write_raw_copy(raw_dir, idx, source)
    return if raw_dir.nil? || source.nil?

    FileUtils.mkdir_p(raw_dir)
    path = File.join(raw_dir, format('%06d', idx))
    File.write(path, source)
    File.chmod(0o444, path)
  rescue Errno::EPERM
    # 只读属性设置失败不影响主流程（Windows/某些文件系统行为不同）
  end

  def run_fetch_media(argv)
    require_relative 'weibo_import/downloader'
    opts = {
      input: nil, media_dir: 'media', max_bytes: WeiboImport::Downloader::DEFAULT_MAX_BYTES,
      timeout: WeiboImport::Downloader::DEFAULT_TIMEOUT_SECONDS, retries: WeiboImport::Downloader::DEFAULT_RETRIES,
      missing_out: 'missing-media.jsonl', results_out: 'media-results.jsonl', headers: {}
    }
    OptionParser.new do |o|
      o.banner = '用法: weibo_normalize.rb fetch-media --input normalized.jsonl --media-dir media/ [options]'
      o.on('--header \'NAME: VALUE\'', '附加请求头（可重复，如防盗链需要的 User-Agent/Referer）') do |v|
        k, val = v.split(':', 2).map(&:strip)
        raise ArgumentError, "--header 格式应为 'Name: Value': #{v.inspect}" if val.nil? || val.empty?

        opts[:headers][k] = val
      end
      o.on('--input PATH', 'normalized.jsonl（必填）') { |v| opts[:input] = v }
      o.on('--media-dir DIR', "媒体目录（默认 #{opts[:media_dir]}）") { |v| opts[:media_dir] = v }
      o.on('--max-bytes N', Integer, "单文件大小上限（默认 #{opts[:max_bytes]}）") { |v| opts[:max_bytes] = v }
      o.on('--timeout N', Integer, "超时秒数（默认 #{opts[:timeout]}）") { |v| opts[:timeout] = v }
      o.on('--retries N', Integer, "重试次数（默认 #{opts[:retries]}）") { |v| opts[:retries] = v }
      o.on('--missing-out PATH', "缺失清单（默认 #{opts[:missing_out]}）") { |v| opts[:missing_out] = v }
      o.on('--results-out PATH', "下载结果清单（默认 #{opts[:results_out]}）") { |v| opts[:results_out] = v }
    end.parse(argv)
    raise ArgumentError, 'fetch-media 需要 --input' if opts[:input].to_s.strip.empty?

    payload = WeiboImport::Normalize.read_records(opts[:input])
    raise ArgumentError, "输入含 #{payload[:parse_errors].length} 个解析错误行；请先修复 normalize 输出" unless payload[:parse_errors].empty?

    FileUtils.mkdir_p(opts[:media_dir])
    stats = { total: 0, skipped_local: 0, ok: 0, failed: 0, no_url: 0, extension_mismatch: 0,
              results_out: opts[:results_out], missing_out: opts[:missing_out] }
    results_f = File.open(opts[:results_out], 'w:UTF-8')
    missing_f = File.open(opts[:missing_out], 'w:UTF-8')

    payload[:records].each_with_index do |rec, ridx|
      Array(rec['media']).each_with_index do |m, midx|
        stats[:total] += 1
        url = m['url'].to_s.strip
        path = m['path'].to_s.strip
        base = { 'record_index' => ridx, 'source_id' => rec['source_id'], 'media_index' => midx, 'url' => (url.empty? ? nil : url) }

        if url.empty?
          if path.empty? || !File.exist?(path)
            stats[:no_url] += 1
            entry = base.merge('status' => 'missing', 'path' => (path.empty? ? nil : path), 'reason' => path.empty? ? '无 URL 且无本地路径' : '无 URL 且本地文件不存在')
            missing_f.puts(JSON.generate(entry))
            results_f.puts(JSON.generate(entry))
          else
            stats[:skipped_local] += 1
            results_f.puts(JSON.generate(base.merge('status' => 'skipped-local', 'path' => path)))
          end
          next
        end

        if !path.empty? && File.exist?(path)
          stats[:skipped_local] += 1
          results_f.puts(JSON.generate(base.merge('status' => 'skipped-local', 'path' => path)))
          next
        end

        begin
          target = WeiboImport::Downloader.safe_target_path(opts[:media_dir], WeiboImport::Downloader.filename_from_uri(URI.parse(url)))
          result = WeiboImport::Downloader.fetch(url, target, max_bytes: opts[:max_bytes], timeout: opts[:timeout], retries: opts[:retries], headers: opts[:headers])
          stats[:ok] += 1
          stats[:extension_mismatch] += 1 if result['extension_mismatch']
          warn "警告: 扩展名与内容不符 #{target}（sniffed=#{result['sniffed_mime']}）" if result['extension_mismatch']
          results_f.puts(JSON.generate(base.merge(result)))
        rescue WeiboImport::Downloader::Rejected, WeiboImport::Downloader::DownloadError, StandardError => e
          stats[:failed] += 1
          entry = base.merge('status' => 'failed', 'path' => nil, 'reason' => "#{e.class}: #{e.message}")
          missing_f.puts(JSON.generate(entry))
          results_f.puts(JSON.generate(entry))
        end
      end
    end
    results_f.close
    missing_f.close
    puts WeiboImport::Report.fetch_summary(stats)
    warn "存在无法获得的媒体（#{stats[:no_url] + stats[:failed]} 条），已显式列出 #{opts[:missing_out]}；绝不悄悄丢弃。" if (stats[:no_url] + stats[:failed]).positive?
    0
  end
end

exit WeiboNormalizeCLI.run(ARGV) if $PROGRAM_NAME == __FILE__
