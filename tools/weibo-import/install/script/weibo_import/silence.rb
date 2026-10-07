# frozen_string_literal: true

# 占位：批次 B 实装——静默回调抑制。
# 原则：只在本次 rails runner 进程内做局部覆盖（Module#prepend / 单例禁用特定回调），
# **禁止**全局禁用回调、禁止全局清空 Sidekiq 入队、禁止改动实例配置文件。
# 需要逐项核实的回调清单见 docs/silent-callbacks-audit.md。
module WeiboImport
  module Silence
    BATCH_NOTE = '批次 B 交付，本批次不可用'

    def self.run(_argv = [])
      $stderr.puts "weibo_import silence: #{BATCH_NOTE}。审计清单见 docs/silent-callbacks-audit.md。"
      2
    end
  end
end
