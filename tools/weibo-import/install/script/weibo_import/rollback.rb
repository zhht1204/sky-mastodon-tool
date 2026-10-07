# frozen_string_literal: true

# 占位：批次 B 实装（薄入口 weibo_import_rollback.rb 委托此处）。
# rollback 将按账本回滚：默认 dry-run；真实回滚时子帖先删、只删本工具创建的帖子、
# 不删他人内容，并注意 RemoveStatusService 会触发联邦删除，需按 docs/weibo-import.md 评估。
module WeiboImport
  module Rollback
    BATCH_NOTE = '批次 B 交付，本批次不可用'

    def self.run(_argv = [])
      $stderr.puts "weibo_import rollback: #{BATCH_NOTE}。回滚风险与顺序见 docs/weibo-import.md。"
      2
    end
  end
end
