#!/usr/bin/env ruby
# frozen_string_literal: true

# weibo_import.rb — 微博归档导入主 CLI。
# 子命令: plan | import | verify | rollback | env-check | setup-ledger
# 批次 A: plan / env-check 真实可用；import / verify / rollback / setup-ledger 为占位（批次 B 交付）。
# plan 无需 Rails（读 normalized.jsonl 纯分析，不碰 DB）；env-check 必须在实例 Rails 环境运行。
require_relative 'weibo_import/cli'
require_relative 'weibo_import/report'
require_relative 'weibo_import/env_check'
require_relative 'weibo_import/importer'
require_relative 'weibo_import/verify'
require_relative 'weibo_import/rollback'
require_relative 'weibo_import/ledger'
require_relative 'weibo_import/backup'

module WeiboImport
  module Main
    module_function

    def run(argv)
      cli = CLI.new
      begin
        cli.parse(argv)
      rescue CLI::ParseFailure => e
        $stderr.puts "参数错误: #{e.message}"
        $stderr.puts cli.usage_text
        return 64
      end

      case cli.subcommand
      when 'plan' then run_plan(cli)
      when 'env-check' then EnvCheck.run(account: cli.options[:account])
      when 'import' then Importer.run(argv)
      when 'verify' then Verify.run(argv)
      when 'rollback' then Rollback.run(argv)
      when 'setup-ledger'
        $stderr.puts "weibo_import setup-ledger: #{Ledger::TABLE_NAME} #{WeiboImport::Importer::BATCH_NOTE}"
        CLI::PLACEHOLDER_EXIT_CODE
      end
    end

    def run_plan(cli)
      opts = cli.options
      payload = begin
        WeiboImport::Normalize.read_records(opts[:input])
      rescue ArgumentError => e
        $stderr.puts "读取输入失败: #{e.message}"
        return 1
      end

      records = payload[:records]
      if payload[:parse_errors] && !payload[:parse_errors].empty?
        $stderr.puts "警告: #{payload[:parse_errors].length} 行 JSON 解析失败（这些行被跳过）："
        payload[:parse_errors].first(5).each { |pe| $stderr.puts "  行 #{pe['line_no']}: #{pe['error']}" }
        records = records.compact
      end

      # Rails 环境下允许调用 env_check 的账号信息部分（只读）；无 Rails 则跳过
      account_note =
        if defined?(Rails)
          facts = begin
            EnvCheck.account_facts(opts[:account])
          rescue StandardError
            { 'account_state' => '不可得' }
          end
          "（实例实测账号状态: #{facts['account_state']}）"
        else
          '（未在 Rails 环境：账号状态未实测）'
        end

      stats = Report.plan_stats(records, limit: opts[:limit])
      text = Report.plan_report(stats, account: opts[:account], visibility: opts[:visibility],
                                    limit: opts[:limit], batch: opts[:batch] || '(未指定)')
      puts "账号检查#{account_note}"
      puts text
      if opts[:report_file]
        require 'fileutils'
        FileUtils.mkdir_p(File.dirname(File.expand_path(opts[:report_file])))
        File.write(opts[:report_file], text)
        $stderr.puts "报告已写入 #{opts[:report_file]}"
      end
      0
    end
  end
end

exit WeiboImport::Main.run(ARGV) if $PROGRAM_NAME == __FILE__
