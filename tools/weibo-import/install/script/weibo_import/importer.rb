# frozen_string_literal: true

# 占位：批次 B 实装。
# import 子命令将按 docs/weibo-import.md 的六阶段流程与确认门执行：
# 账本登记 → 静默回调抑制（局部）→ 逐条创建 Status（Snowflake 回填历史时间）→ 媒体挂载。
# 本批次不做任何生产写入。
module WeiboImport
  module Importer
    BATCH_NOTE = '批次 B 交付，本批次不可用'

    def self.run(_argv = [])
      $stderr.puts "weibo_import import: #{BATCH_NOTE}。请先完成 env-check 与备份，再等待批次 B。"
      2
    end
  end
end
