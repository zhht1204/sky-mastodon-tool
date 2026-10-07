# frozen_string_literal: true

# 导入器（批次 B 实装）：normalized.jsonl → Mastodon Status。
#
# 核心不变量：
# 1. created_at = 来源时间（UTC 存储）；updated_at = 本次写入（Rails 自动）；
#    edited_at 不设——不伪装编辑过。
# 2. Status.id = 预分配确定性历史 Snowflake ID（时间位=来源毫秒，同毫秒序列递增，
#    父帖 ID < 子帖 ID）；status.override_timestamps = true 使部署版 Snowflake
#    回调走 yield 分支、不覆盖显式 ID（4.6.2 源码核实）。
# 3. Status 创建与账本行写入同一事务；媒体行在事务外先建（与 PostStatusService
#    同构），失败段产生的孤儿媒体行在本次运行结束时清理。
# 4. 绝不调用 PostStatusService（无时间线分发/提及/联邦）；Silence.apply!
#    抑制 webhook/FASP/活跃度统计（见 silence.rb 审计）。
# 5. 不创建 Mention / Notification / Poll / Favourite / boost。
# 6. 幂等：账本 (account, source, source_id, segment_no) 唯一约束 + 运行前
#    预检；内容哈希变化报冲突，不自动重发。
module WeiboImport
  module Importer
    DEFAULT_LANGUAGE = 'zh'
    DEFAULT_MEDIA_DIR_NAME = 'media'

    ImportFailure = Class.new(StandardError)

    module_function

    def run(cli)
      opts = cli.options
      return placeholder_guard unless defined?(Rails)

      require_relative 'normalize'
      require_relative 'splitter'
      require_relative 'id_allocator'
      require_relative 'ledger'
      require_relative 'silence'
      require_relative 'downloader'

      begin
        execute(opts)
      rescue StandardError => e
        $stderr.puts "导入失败: #{e.class}: #{e.message}"
        $stderr.puts e.backtrace.first(8) if ENV['WEIBO_IMPORT_DEBUG']
        return 1
      end
    end

    def execute(opts)
      validate_options!(opts)
      media_dir = opts[:media_dir] || File.expand_path(DEFAULT_MEDIA_DIR_NAME, File.dirname(File.expand_path(opts[:input])))
      batch = opts[:batch]

      account = find_account!(opts[:account])
      conn = ActiveRecord::Base.connection
      raise '账本表不存在：先执行 setup-ledger --execute' unless Ledger.exists?(conn)

      payload = Normalize.read_records(opts[:input])
      raise ArgumentError, "输入含 #{payload[:parse_errors].length} 个解析错误行" unless payload[:parse_errors].empty?

      records = sort_records(payload[:records].compact)
      records = records.first(opts[:limit]) if opts[:limit]

      run_start = Time.now.utc
      ctx = {
        account: account, conn: conn, batch: batch, visibility: opts[:visibility],
        language: opts[:language] || DEFAULT_LANGUAGE, media_dir: media_dir,
        allocator: IdAllocator::Allocator.new, map_out: opts[:map_out] || "import-map-#{batch}.jsonl",
        counters: Hash.new(0), failures: [], conflicts: [], partial: [], map_lines: []
      }

      # 批次续跑守卫：同一批次已有行时必须显式 --resume
      unless opts[:resume]
        existing = conn.select_value(<<~SQL.squish).to_i
          SELECT COUNT(*) FROM #{Ledger::TABLE_NAME}
          WHERE account_id = #{account.id} AND batch = #{conn.quote(batch)}
        SQL
        raise "批次 #{batch} 已有 #{existing} 行账本记录；续跑需 --resume，或换用新批次号" if existing.positive?
      end

      return dry_run(ctx, records) unless opts[:execute]

      confirm_or_abort!(opts)

      acquired = Ledger.acquire_lock!(conn, account.id)
      raise "获取导入锁失败（另一导入进程持有 #{Ledger.lock_key(account.id)}）" unless acquired

      Silence.apply!
      begin
        import_records(ctx, records)
      ensure
        Ledger.release_lock!(conn, account.id)
        cleanup_orphan_media(ctx, run_start)
      end

      write_map_file(ctx)
      puts Silence.audit_report
      puts summary(ctx, records.length)
      print_failure_details(ctx)
      0
    end

    # ---- 纯逻辑（可单测）----

    # 按创建时间升序处理（父帖先创建）；同时间按 source_id 稳定排序
    def sort_records(records)
      records.sort_by { |r| [r['created_at'].to_s, r['source_id'].to_s] }
    end

    # 来源毫秒（ID 时间位）；无法解析的时间已在 normalize 阶段进错误清单
    def source_ms(created_at_str)
      (DateTime.parse(created_at_str).to_time.utc.to_f * 1000).to_i
    end

    # 媒体项 → 本地文件路径（fetch-media 下载命名规则）；返回 [path, missing]
    def resolve_media_path(media_dir, media_item)
      local = media_item['path'].to_s.strip
      return [local, false] if !local.empty? && File.exist?(local)

      url = media_item['url'].to_s.strip
      if !url.empty?
        filename = Downloader.filename_from_uri(URI.parse(url))
        candidate = File.join(media_dir, filename)
        return [candidate, false] if File.exist?(candidate)

        return [nil, true] # 有 URL 但本地文件缺失
      end
      [nil, true]
    end

    # 幂等预检：:skip（全段已导入）/ :partial_skip（有 partial 段，避免重复不再写）/
    # :conflict（内容哈希变化）/ :new（无行或全部已回滚——允许重新导入）
    def precheck(existing_rows, line_hash)
      return :new if existing_rows.empty?
      return :new if existing_rows.all? { |r| r['state'] == 'rolled_back' }

      hashes = existing_rows.map { |r| r['normalized_hash'] }.uniq
      return :conflict unless hashes == [line_hash]

      return :partial_skip if existing_rows.any? { |r| r['state'] == 'partial' }

      :skip
    end

    def build_segments(record)
      suffix = record['source_url'] ? "\n#{record['source_url']}" : nil
      WeiboImport::Splitter.segments(record, first_post_suffix: suffix)
    end

    def summary(ctx, total)
      c = ctx[:counters]
      <<~TEXT
        == import 汇总 ==
        来源微博处理数  : #{total}
        完整导入        : #{c[:complete]}
        部分导入        : #{c[:partial]}（明细 #{ctx[:partial].length} 条）
        失败            : #{c[:failed]}（明细 #{ctx[:failures].length} 条）
        跳过（已导入）  : #{c[:skipped]}
        跳过（部分导入）: #{c[:skipped_partial]}
        冲突（哈希变化） : #{c[:conflict]}
        创建帖子数      : #{c[:statuses]}
        创建媒体数      : #{c[:media]}
        孤儿媒体清理    : #{c[:orphan_media_cleaned]}
        映射文件        : #{ctx[:map_out]}
      TEXT
    end

    # ---- Rails 环境内部流程 ----

    def validate_options!(opts)
      raise ArgumentError, 'import 需要 --account' if opts[:account].to_s.strip.empty?
      raise ArgumentError, 'import 需要 --input' if opts[:input].to_s.strip.empty?
      raise ArgumentError, 'import 需要 --batch（批次标识，供回滚与审计）' if opts[:batch].to_s.strip.empty?
    end

    def placeholder_guard
      $stderr.puts 'weibo_import import: 必须在 Mastodon Rails 环境运行（rails runner）。'
      2
    end

    def find_account!(username)
      account = Account.find_local(username.to_s.strip)
      raise "账号不存在或非本地账号: #{username}" if account.nil?

      raise "账号已被停用: #{username}" if account.suspended?
      raise '账号所属用户未确认或未审批' if account.user.nil? || !account.user.confirmed? || account.user_pending?

      account
    end

    def confirm_or_abort!(opts)
      return if opts[:yes]

      if $stdin.tty?
        print "将在实例上创建帖子（批次 #{opts[:batch]}）。输入 yes 继续: "
        raise '已中止' unless $stdin.gets.to_s.strip.casecmp('yes').zero?
      else
        raise '非交互环境必须显式 --yes（表示已通过确认门）'
      end
    end

    def dry_run(ctx, records)
      c = ctx[:counters]
      records.each do |rec|
        segs = build_segments(rec)
        media_count = segs.sum { |s| s['media'].length }
        missing = segs.sum { |s| s['media'].count { |m| resolve_media_path(ctx[:media_dir], m)[1] } }
        c[:planned_records] += 1
        c[:planned_statuses] += segs.length
        c[:planned_media] += media_count
        c[:planned_missing_media] += missing
      end
      puts '== import dry-run（不写入）=='
      puts "来源微博: #{c[:planned_records]} → 预计帖子: #{c[:planned_statuses]}，媒体: #{c[:planned_media]}（缺失文件 #{c[:planned_missing_media]}，对应记录将标为部分导入）"
      puts '加 --execute 执行真实导入。'
      0
    end

    def import_records(ctx, records)
      conn = ctx[:conn]
      records.each do |rec|
        line_hash = Digest::SHA256.hexdigest(JSON.generate(rec))
        existing = Ledger.rows_for(conn, ctx[:account].id, rec['source'], rec['source_id'])
        case precheck(existing, line_hash)
        when :skip
          ctx[:counters][:skipped] += 1
          next
        when :partial_skip
          ctx[:counters][:skipped_partial] += 1
          ctx[:partial] << { 'source_id' => rec['source_id'], 'reason' => '存在 partial 段（如缺媒体），跳过避免重复；如需重建请先回滚该批次' }
          next
        when :conflict
          ctx[:counters][:conflict] += 1
          ctx[:conflicts] << { 'source_id' => rec['source_id'], 'existing' => existing.map { |r| r['normalized_hash'] }.uniq, 'current' => line_hash }
          next
        end

        import_one_record(ctx, rec, line_hash)
      rescue StandardError => e
        ctx[:counters][:failed] += 1
        ctx[:failures] << { 'source_id' => rec['source_id'], 'error' => "#{e.class}: #{e.message}" }
      end
    end

    def import_one_record(ctx, rec, line_hash)
      segs = build_segments(rec)
      parent = nil
      seg_missing = []
      created_status_ids = []

      segs.each do |seg|
        media_paths = seg['media'].map { |m| resolve_media_path(ctx[:media_dir], m) }
        missing_here = seg['media'].select.with_index { |_m, i| media_paths[i][1] }
        seg_missing.concat(missing_here.map { |m| m['url'] || m['path'] })

        mas = media_paths.reject { |_, missing| missing }.map { |path, _| create_media!(ctx, path) }

        status = nil
        ActiveRecord::Base.transaction do
          status = create_status!(ctx, seg, mas, parent)
          Ledger.insert_row!(ctx[:conn],
                             account_id: ctx[:account].id, source: rec['source'], source_id: rec['source_id'],
                             segment_no: seg['segment_no'], normalized_hash: line_hash,
                             source_created_at: Time.parse(seg['created_at']).utc.iso8601,
                             visibility: ctx[:visibility], batch: ctx[:batch],
                             status_id: status.id, media_attachment_ids: mas.map(&:id),
                             state: missing_here.empty? ? 'imported' : 'partial',
                             error: missing_here.empty? ? nil : "missing media: #{missing_here.map { |m| m['url'] || m['path'] }.join(', ')}")
        end
        parent = status
        created_status_ids << status.id
        ctx[:counters][:statuses] += 1
        ctx[:counters][:media] += mas.length
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        raise ImportFailure, "段 #{seg['segment_no']} 创建失败: #{e.class}: #{e.message}"
      end

      ctx[:map_lines] << { 'source_id' => rec['source_id'], 'source_url' => rec['source_url'],
                           'status_ids' => created_status_ids,
                           'first_status_url' => status_url(ctx, created_status_ids.first) }
      if seg_missing.empty?
        ctx[:counters][:complete] += 1
      else
        ctx[:counters][:partial] += 1
        ctx[:partial] << { 'source_id' => rec['source_id'], 'missing_media' => seg_missing }
      end
    end

    def create_media!(ctx, path)
      ma = MediaAttachment.new(account: ctx[:account])
      ma.file = File.open(path, 'rb')
      ma.save!
      ma
    end

    def create_status!(ctx, seg, media_attachments, parent)
      created_at = Time.parse(seg['created_at']).utc
      status = Status.new(
        account: ctx[:account],
        text: seg['text'],
        visibility: ctx[:visibility],
        language: ctx[:language],
        sensitive: false,
        spoiler_text: '',
        created_at: created_at,
        # updated_at 不设 → Rails 记录本次写入时间；edited_at 不设
        thread: parent,
        media_attachments: media_attachments,
        ordered_media_attachment_ids: media_attachments.map(&:id)
      )
      status.override_timestamps = true # Snowflake 回调走 yield 分支，不覆盖显式 ID
      status.id = allocate_id!(ctx, Importer.source_ms(seg['created_at']))
      status.save!
      status
    end

    # 确定性 ID：同毫秒序列递增（父<子）；与既有 ID 冲突时 bump 序列重试
    def allocate_id!(ctx, ms)
      allocator = ctx[:allocator]
      loop do
        candidate = allocator.next_id_at(ms)
        return candidate unless Status.exists?(id: candidate)

        allocator.reserve(candidate)
      end
    end

    def status_url(ctx, status_id)
      return nil if status_id.nil?

      s = Status.find_by(id: status_id)
      return nil if s.nil?

      s.url || "#{Rails.configuration.x.use_https ? 'https' : 'http'}://#{Rails.configuration.x.web_domain}/@#{ctx[:account].username}/#{status_id}"
    end

    # 本次运行内创建但未挂到任何帖子的媒体行（失败段残留）→ 删除（含存储文件）
    def cleanup_orphan_media(ctx, run_start)
      rows = Ledger.orphan_media_since(ctx[:conn], ctx[:account].id, run_start.iso8601)
      return if rows.empty?

      rows.each { |r| MediaAttachment.find_by(id: r['id'])&.destroy }
      ctx[:counters][:orphan_media_cleaned] = rows.length
      warn "已清理 #{rows.length} 个孤儿媒体行（失败段残留，含存储文件）"
    end

    def write_map_file(ctx)
      return if ctx[:map_lines].empty?

      File.open(ctx[:map_out], 'a:UTF-8') do |f|
        ctx[:map_lines].each { |l| f.puts(JSON.generate(l)) }
      end
    end

    def print_failure_details(ctx)
      return if ctx[:failures].empty? && ctx[:conflicts].empty?

      puts '失败明细（前 10 条）:' if ctx[:failures].any?
      ctx[:failures].first(10).each { |f| puts "  #{f['source_id']}: #{f['error']}" }
      puts '冲突明细（前 10 条）:' if ctx[:conflicts].any?
      ctx[:conflicts].first(10).each { |c| puts "  #{c['source_id']}: existing=#{c['existing'].join(',')} current=#{c['current']}" }
    end
  end
end
