# frozen_string_literal: true

# 占位：批次 B 实装（薄入口 weibo_import_verify.rb 委托此处）。
# verify 将按账本逐条核对：status 存在性、文本/时间/可见性/媒体数量、拆分段数、
# 计数口径（完整成功/部分/失败/跳过重复），输出核对报告。
module WeiboImport
  module Verify
    BATCH_NOTE = '批次 B 交付，本批次不可用'

    def self.run(_argv = [])
      $stderr.puts "weibo_import verify: #{BATCH_NOTE}。"
      2
    end
  end
end
