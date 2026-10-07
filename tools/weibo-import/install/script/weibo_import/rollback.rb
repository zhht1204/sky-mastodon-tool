# frozen_string_literal: true

# rollback（批次 B 实装）：按账本回滚一个批次。
#
# 语义（对应任务书回滚要求）：
# - 默认 dry-run：只列出将被删除的帖子和检查结果，不写入。
# - 真实回滚需 --execute；子帖先于父帖删除（segment_no 降序）。
# - 只操作账本登记的帖子和媒体行；绝不触碰本批次之外的任何帖子。
# - 删除前检查新互动（他人回复/收藏/转发/提及本批次帖子）：有则默认停止，
#   --force 才继续。
# - Status#destroy 是 AR 硬删除（discard 只是软删方法），本地回调会修正
#   statuses_count/replies_count/conversation 与搜索索引；不走 RemoveStatusService，
#   因此不会向远端联邦发送删除——远端已获取的副本本地无法收回（须知会管理员）。
# - 媒体关联为 nullify，故账本登记的 media_attachment_ids 需显式销毁（含文件）。
module WeiboImport
  module Rollback
    module_function

    def run(cli)
      opts = cli.options
      unless defined?(Rails)
        $stderr.puts 'rollback 必须在 Mastodon Rails 环境运行（rails runner）。'
        return 2
      end
      raise ArgumentError, 'rollback 需要 --account' if opts[:account].to_s.strip.empty?
      raise ArgumentError, 'rollback 需要 --batch' if opts[:batch].to_s.strip.empty?

      require_relative 'weibo_import/ledger'

      account = Account.find_local(opts[:account].to_s.strip)
      raise "账号不存在: #{opts[:account]}" if account.nil?

      conn = ActiveRecord::Base.connection
      rows = Ledger.batch_rows(conn, account.id, opts[:batch]).select { |r| r['state'] != 'rolled_back' }
      raise "批次 #{opts[:batch]} 无可回滚账本行" if rows.empty?

      interactions = find_new_interactions(rows)
      unless interactions.empty?
        return blocked_report(opts[:batch], interactions) unless opts[:force]

        warn "发现 #{interactions.length} 条新互动，--force 已确认继续"
      end

      return dry_run_report(rows, interactions) unless opts[:execute]

      confirm_or_abort!(opts)

      deleted_statuses = 0
      deleted_media = 0
      # 子帖先删（segment_no 降序）；同段无依赖
      rows.sort_by { |r| [-r['segment_no'], -r['id'].to_i] }.each do |row|
        status = Status.find_by(id: row['status_id'])
        media_ids = JSON.parse(row['media_attachment_ids'].to_s)

        if status
          status.destroy
          deleted_statuses += 1
        end
        # 媒体 nullify 后仍归本账号；只有不再被其他帖子引用时才删
        media_ids.each do |mid|
          ma = MediaAttachment.find_by(id: mid)
          next if ma.nil?

          if ma.status_id.nil?
            ma.destroy
            deleted_media += 1
          else
            warn "媒体 #{mid} 已被帖子 #{ma.status_id} 引用，跳过删除"
          end
        end
        Ledger.mark_rolled_back!(conn, row['id'])
      end

      puts <<~TEXT
        == rollback 汇总（#{opts[:batch]}）==
        删除帖子: #{deleted_statuses}
        删除媒体: #{deleted_media}
        账本行已标记 rolled_back。
        注：远端已获取的联邦副本无法由本地回滚收回。
      TEXT
      0
    rescue StandardError => e
      $stderr.puts "rollback 失败: #{e.class}: #{e.message}"
      1
    end

    # 检查新互动：他人对本批次帖子的回复 / 收藏 / 转发 / 提及
    def find_new_interactions(rows)
      status_ids = rows.filter_map { |r| r['status_id'] }
      return [] if status_ids.empty?

      out = []
      Status.where(in_reply_to_id: status_ids).where.not(id: status_ids).find_each do |s|
        out << { 'type' => 'reply', 'from' => s.account.acct, 'status_id' => s.in_reply_to_id }
      end
      Favourite.where(status_id: status_ids).find_each do |f|
        out << { 'type' => 'favourite', 'from' => f.account.acct, 'status_id' => f.status_id }
      end
      Status.where(reblog_of_id: status_ids).find_each do |s|
        out << { 'type' => 'reblog', 'from' => s.account.acct, 'status_id' => s.reblog_of_id }
      end
      Mention.where(status_id: status_ids).find_each do |m|
        out << { 'type' => 'mention', 'from' => m.account.acct, 'status_id' => m.status_id }
      end
      out
    end

    def dry_run_report(rows, interactions)
      media_count = rows.sum { |r| JSON.parse(r['media_attachment_ids'].to_s).length }
      <<~TEXT
        == rollback dry-run（批次 #{rows.first['batch']}）==
        将删除帖子 : #{rows.filter_map { |r| r['status_id'] }.uniq.length}
        将删除媒体 : #{media_count}（仅不再被引用的）
        新互动检查 : #{interactions.length} 条#{interactions.empty? ? '' : '（真实回滚默认停止，需 --force）'}
        加 --execute 执行真实回滚。
      TEXT
    end

    def blocked_report(batch, interactions)
      sample = interactions.first(5).map { |i| "#{i['type']} by #{i['from']} on #{i['status_id']}" }.join('; ')
      $stderr.puts "rollback 阻止：批次 #{batch} 的帖子存在新互动（#{interactions.length} 条，如 #{sample}）。"
      $stderr.puts '确认要连同这些互动一起删除时使用 --force --execute。'
      3
    end

    def confirm_or_abort!(opts)
      return if opts[:yes]

      if $stdin.tty?
        print "将真实删除批次 #{opts[:batch]} 的帖子和媒体。输入 yes 继续: "
        raise '已中止' unless $stdin.gets.to_s.strip.casecmp('yes').zero?
      else
        raise '非交互环境必须显式 --yes'
      end
    end
  end
end
