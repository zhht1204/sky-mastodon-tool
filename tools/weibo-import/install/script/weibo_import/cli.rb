# frozen_string_literal: true

# weibo_import.rb 的参数解析（optparse）。
# 语义约定：--limit N = 前 N 条「来源微博」（不是拆分后帖子数），plan 与 import 一致；
# --visibility 默认 unlisted，非公开内容只能同级或更严格（收紧），绝不放宽。
require 'optparse'

module WeiboImport
  DEFAULT_VISIBILITY = 'unlisted'

  class CLI
    VALID_SUBCOMMANDS = %w[plan import verify rollback env-check setup-ledger].freeze
    PLACEHOLDER_SUBCOMMANDS = %w[import verify rollback].freeze
    PLACEHOLDER_EXIT_CODE = 2

    class ParseFailure < StandardError; end

    attr_reader :subcommand, :options, :parser

    def initialize
      @options = {
        account: nil,
        input: nil,
        visibility: DEFAULT_VISIBILITY,
        limit: nil,
        batch: nil,
        resume: false,
        dry_run: true,
        report_file: nil,
        execute: false,
        yes: false
      }
      @parser = build_parser
    end

    # 解析 argv；失败时打印错误并抛 ParseFailure（入口转 64 退出码）
    def parse(argv)
      rest = begin
        @parser.parse(argv)
      rescue OptionParser::InvalidArgument, OptionParser::InvalidOption, OptionParser::MissingArgument => e
        raise ParseFailure, e.message
      end
      @subcommand = rest.shift
      raise ParseFailure, "缺少子命令（可选: #{VALID_SUBCOMMANDS.join(' | ')}）" if @subcommand.nil?
      raise ParseFailure, "未知子命令: #{@subcommand}（可选: #{VALID_SUBCOMMANDS.join(' | ')}）" unless VALID_SUBCOMMANDS.include?(@subcommand)
      raise ParseFailure, "多余的参数: #{rest.join(' ')}" unless rest.empty?

      validate!
      self
    end

    def validate!
      return unless @subcommand == 'plan'

      raise ParseFailure, 'plan 需要 --account <本地账号>' if @options[:account].to_s.strip.empty?
      raise ParseFailure, 'plan 需要 --input <normalized.jsonl>' if @options[:input].to_s.strip.empty?
    end

    def placeholder?
      PLACEHOLDER_SUBCOMMANDS.include?(@subcommand)
    end

    def usage_text
      @parser.to_s
    end

    private

    def build_parser
      OptionParser.new do |o|
        o.banner = "用法: weibo_import.rb <#{VALID_SUBCOMMANDS.join('|')}> [options]"
        o.separator ''
        o.separator '子命令:'
        o.separator '  plan         预演报告（只读；无 Rails 也能跑）'
        o.separator '  import       真实导入（批次 B；需 Rails + --execute）'
        o.separator '  verify       导入后核对（批次 B；需 Rails）'
        o.separator '  rollback     回滚（批次 B；需 Rails；默认 dry-run，真实回滚需 --execute）'
        o.separator '  env-check    实例环境只读检查（需 rails runner 环境）'
        o.separator '  setup-ledger 创建导入账本表（需 Rails + --execute）'
        o.separator ''
        o.separator '选项:'
        o.on('--account USER', '目标 Mastodon 本地账号（用户名，不含域名）') { |v| @options[:account] = v }
        o.on('--input PATH', '输入文件（normalized.jsonl）') { |v| @options[:input] = v }
        o.on('--visibility VIS', %w[public unlisted private direct], '导入可见性，默认 unlisted；只能收紧不能放宽') do |v|
          @options[:visibility] = v
        end
        o.on('--limit N', Integer, '只处理前 N 条来源微博（非拆分后帖子数）') { |v| @options[:limit] = v }
        o.on('--batch ID', '批次 ID（账本/报告标识）') { |v| @options[:batch] = v }
        o.on('--resume', '从账本断点续跑（批次已有账本行时必须显式指定）') { @options[:resume] = true }
        o.on('--language LANG', "帖子语言标记，默认 #{'zh'}（微博内容固定 zh）") { |v| @options[:language] = v }
        o.on('--media-dir DIR', '媒体文件目录（默认 <input 所在目录>/media；须与 fetch-media 输出一致）') { |v| @options[:media_dir] = v }
        o.on('--map-out PATH', '微博 ID → Mastodon 帖子映射输出（JSONL，默认 import-map-<batch>.jsonl）') { |v| @options[:map_out] = v }
        o.on('--[no-]dry-run', '只预演不写入（默认开启）') { |v| @options[:dry_run] = v }
        o.on('--report-file PATH', '预演报告输出文件（markdown）') { |v| @options[:report_file] = v }
        o.on('--execute', '真实执行（危险；仅批次 B 起对写命令生效）') { @options[:execute] = true }
        o.on('--yes', '跳过逐项确认（危险，仅隔离演练用）') { @options[:yes] = true }
      end
    end
  end
end
