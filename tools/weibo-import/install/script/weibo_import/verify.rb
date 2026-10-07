# frozen_string_literal: true

# verify（批次 B 实装）：按账本逐行核对已导入数据。
# 检查项（对应任务书验收清单）：
#   1. 帖子存在且 account 匹配
#   2. created_at == 账本 source_created_at（毫秒级一致）
#   3. ID 时间位 == 来源毫秒（证明 override_timestamps 显式 ID 未被覆盖）
#   4. visibility 与账本一致
#   5. ordered_media_attachment_ids == 账本记录（含顺序）
#   6. 串内回复链正确（段 N 的 in_reply_to == 段 N-1）
#   7. 无 Mention / 无关联 Notification（不伪造互动）
#   8. edited_at 为空（不伪装编辑）
#   9. 账号统计与队列快照（信息性输出）
module WeiboImport
  module Verify
    module_function

    def run(cli)
      opts = cli.options
      unless defined?(Rails)
        $stderr.puts 'verify 必须在 Mastodon Rails 环境运行（rails runner）。'
        return 2
      end
      raise ArgumentError, 'verify 需要 --account' if opts[:account].to_s.strip.empty?
      raise ArgumentError, 'verify 需要 --batch 或 --input 之一（按账本核对）' if opts[:batch].to_s.strip.empty?

      require_relative 'weibo_import/ledger'
      require_relative 'weibo_import/id_allocator'

      account = Account.find_local(opts[:account].to_s.strip)
      raise "账号不存在: #{opts[:account]}" if account.nil?

      conn = ActiveRecord::Base.connection
      rows = Ledger.batch_rows(conn, account.id, opts[:batch])
      raise "批次 #{opts[:batch]} 无账本记录" if rows.empty?

      results = rows.map { |row| check_row(account, row) }
      failures = results.reject { |r| r[:ok] }

      puts report(rows, results, failures, account)
      failures.empty? ? 0 : 1
    rescue StandardError => e
      $stderr.puts "verify 失败: #{e.class}: #{e.message}"
      1
    end

    def check_row(account, row)
      status = Status.find_by(id: row['status_id'])
      return { ok: false, row:, reason: "status #{row['status_id']} 不存在" } if status.nil?
      return { ok: false, row:, reason: 'account 不匹配' } unless status.account_id == account.id

      expected_at = Time.parse(row['source_created_at'].to_s).utc
      return { ok: false, row:, reason: "created_at 偏移 #{status.created_at.utc.iso8601} != #{expected_at.iso8601}" } if (status.created_at.utc - expected_at).abs >= 0.001

      ms, = IdAllocator.unpack(status.id)
      return { ok: false, row:, reason: "ID 时间位 #{ms} != 来源毫秒 #{expected_at.to_i * 1000}" } if (ms - expected_at.to_i * 1000).abs >= 1

      return { ok: false, row:, reason: "visibility #{status.visibility} != #{row['visibility']}" } unless status.visibility == row['visibility']

      expected_media = JSON.parse(row['media_attachment_ids'].to_s)
      actual_media = status.ordered_media_attachment_ids || []
      return { ok: false, row:, reason: "媒体顺序 #{actual_media} != #{expected_media}" } unless actual_media.map(&:to_i) == expected_media

      if Mention.exists?(status_id: status.id)
        return { ok: false, row:, reason: '存在 Mention 记录（不应创建）' }
      end
      if Notification.exists?(activity_type: 'Status', activity_id: status.id)
        return { ok: false, row:, reason: '存在关联 Notification（不应创建）' }
      end
      return { ok: false, row:, reason: "edited_at 非空: #{status.edited_at.inspect}" } unless status.edited_at.nil?

      { ok: true, row:, status: }
    end

    def check_threads(rows)
      by_source = rows.group_by { |r| r['source_id'] }
      breaks = []
      by_source.each_value do |src_rows|
        src_rows.sort_by { |r| r['segment_no'] }.each_cons(2) do |prev, cur|
          s = Status.find_by(id: cur['status_id'])
          breaks << { 'source_id' => cur['source_id'], 'segment' => cur['segment_no'] } if s.nil? || s.in_reply_to_id != prev['status_id']
        end
      end
      breaks
    end

    def report(rows, results, failures, account)
      imported = rows.count { |r| r['state'] == 'imported' }
      partial = rows.count { |r| r['state'] == 'partial' }
      rolled = rows.count { |r| r['state'] == 'rolled_back' }
      threads = defined?(Rails) ? check_threads(rows) : []
      queue_sizes = Sidekiq::Queue.all.to_h { |q| [q.name, q.size] } rescue '(Sidekiq 不可用)'

      <<~TEXT
        == verify 汇总 ==
        账本行          : #{rows.length}（imported=#{imported} partial=#{partial} rolled_back=#{rolled}）
        逐行核对失败    : #{failures.length}
        串内回复链断点  : #{threads.length}
        账号统计        : statuses_count=#{account.statuses_count} last_status_at=#{account.last_status_at&.iso8601}
        队列快照        : #{queue_sizes.inspect}
        结果            : #{failures.empty? && threads.empty? ? 'PASS' : 'FAIL'}
      TEXT
    end
  end
end
