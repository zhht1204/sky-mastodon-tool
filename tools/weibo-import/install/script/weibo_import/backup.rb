# frozen_string_literal: true

# 备份编排：默认 dry-run 只打印备份计划；--execute 且逐项确认（y/N，或显式 --yes）才执行。
# 本批次交付代码与纯逻辑单测；不在任何实例上执行。
#
# 步骤（全部可配置路径）：
#   1) pg_dump 数据库（连接参数从 Mastodon ENV 读取：DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASS；
#      密码通过 PGPASSWORD 环境变量传递，绝不进命令行参数；日志一律掩码）
#   2) 媒体目录 tar（S3 场景只生成保护清单并提示手动处理）
#   3) .env.production 与密钥文件复制（目标权限 600）
#   4) 导入前账号统计基线快照 JSON（需 Rails；无 Rails 时跳过并注明）
require 'optparse'
require 'fileutils'
require 'json'

module WeiboImport
  module Backup
    DEFAULTS = {
      out: 'backups',
      pg_dump_bin: 'pg_dump',
      tar_bin: 'tar',
      media_path: nil,          # 默认从 ENV['PAPERCLIP_ROOT_PATH'] 或 public/system 探测
      env_file: '.env.production',
      keys_dir: nil,            # 可选：密钥目录（Mastodon 密钥多在 env 文件内，保留可配置）
      account: nil
    }.freeze

    module_function

    # ---- 纯逻辑（单测覆盖）-------------------------------------------------------

    # 生成 pg_dump 命令（密码绝不进 argv；通过 PGPASSWORD 传递）
    def pg_dump_command(env, out_path, bin: DEFAULTS[:pg_dump_bin])
      db = env['DB_NAME'] || env['DB_DATABASE']
      raise ArgumentError, 'ENV 缺少 DB_NAME/DB_DATABASE（应在 Mastodon .env.production 中）' if db.to_s.strip.empty?

      host = env['DB_HOST'] || 'localhost'
      port = env['DB_PORT'] || '5432'
      user = env['DB_USER'] || 'mastodon'
      "#{bin} --no-owner --no-privileges -h #{shq(host)} -p #{shq(port)} -U #{shq(user)} -d #{shq(db)} -f #{shq(out_path)}"
    end

    def pg_env(env)
      { 'PGPASSWORD' => env['DB_PASS'] || env['DB_PASSWORD'] }
    end

    # 日志安全：命令行里本就不含密码；对任意字符串再兜底掩码 password=...
    def mask_command(cmd)
      cmd.to_s.gsub(/(PGPASSWORD=)[^\s]*/) { "#{Regexp.last_match(1)}***" }
    end

    def tar_command(media_path, out_path, bin: DEFAULTS[:tar_bin])
      raise ArgumentError, '媒体路径为空' if media_path.to_s.strip.empty?

      "#{bin} -czf #{shq(out_path)} -C #{shq(File.dirname(media_path))} #{shq(File.basename(media_path))}"
    end

    def shq(s)
      "'#{s.to_s.gsub("'", "'\\\\''")}'"
    end

    def build_steps(env, opts)
      out = opts[:out]
      FileUtils.mkdir_p(out)
      steps = []

      dump_path = File.join(out, "pg_dump_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.sql")
      steps << {
        name: 'pg_dump',
        description: "PostgreSQL 逻辑备份 -> #{dump_path}",
        command: pg_dump_command(env, dump_path, bin: opts[:pg_dump_bin]),
        env: pg_env(env),
        danger: '数据库级操作（只读导出），占用实例 IO'
      }

      media_path = opts[:media_path] || env['PAPERCLIP_ROOT_PATH'] || 'public/system'
      s3 = env['S3_ENABLED'].to_s.casecmp('true').zero?
      if s3
        steps << {
          name: 'media-manifest(s3)',
          description: "S3 已启用（bucket=#{env['S3_BUCKET']}）：本工具只生成保护清单，对象备份请手动处理（见描述）",
          command: nil,
          manifest: File.join(out, 'media_protection_manifest.txt'),
          danger: 'S3 对象不在本机，无法 tar；请手动完成 bucket 备份/加锁'
        }
      else
        tar_path = File.join(out, "media_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.tar.gz")
        steps << {
          name: 'media-tar',
          description: "媒体目录打包 #{media_path} -> #{tar_path}",
          command: tar_command(media_path, tar_path, bin: opts[:tar_bin]),
          danger: '大目录打包，注意磁盘空间'
        }
      end

      steps << {
        name: 'env-and-keys',
        description: "复制 #{opts[:env_file]}#{opts[:keys_dir] ? " 与 #{opts[:keys_dir]}/" : ''} 到 #{out}/secrets/（权限 600）",
        command: nil,
        copy_targets: [opts[:env_file], opts[:keys_dir]].compact,
        dest_dir: File.join(out, 'secrets'),
        danger: '敏感文件；备份目录本身必须限制访问权限'
      }

      steps << {
        name: 'account-baseline',
        description: "账号统计基线快照 -> #{File.join(out, 'account_baseline.json')}#{'（需 Rails；无 Rails 环境将跳过）' unless rails_available?}",
        command: nil,
        account: opts[:account],
        danger: '只读查询'
      }
      steps
    end

    def rails_available?
      defined?(Rails) && Rails.respond_to?(:root)
    end

    # ---- 编排 ---------------------------------------------------------------------

    def run(argv)
      opts = parse(argv)
      env = ENV.to_h
      steps = build_steps(env, opts)

      puts "== weibo-import 备份计划（#{opts[:execute] ? 'EXECUTE' : 'DRY-RUN'}）=="
      steps.each do |step|
        puts "\n[#{step[:name]}] #{step[:description]}"
        puts "  风险: #{step[:danger]}"
        puts "  命令: #{step[:command] ? mask_command(step[:command]) : '(非命令步骤)'}"
      end
      puts "\n目标目录: #{File.expand_path(opts[:out])}"

      unless opts[:execute]
        puts 'DRY-RUN：未执行任何操作。确认后追加 --execute（并逐项确认，或显式 --yes）。'
        return 0
      end

      steps.each do |step|
        confirmed = opts[:yes] || confirm("执行步骤 [#{step[:name]}]?")
        next(puts "  跳过 [#{step[:name]}]") unless confirmed

        execute_step(step, env, opts)
      end
      0
    end

    def execute_step(step, env, opts)
      case step[:name]
      when 'pg_dump'
        rc = system({ 'PGPASSWORD' => env['DB_PASS'] || env['DB_PASSWORD'] || '' }, step[:command])
        raise "pg_dump 失败（退出码 #{$?.exitstatus}）" unless rc
      when 'media-tar'
        rc = system(step[:command])
        raise "tar 失败（退出码 #{$?.exitstatus}）" unless rc
      when 'media-manifest(s3)'
        File.write(step[:manifest], "S3 bucket=#{env['S3_BUCKET']} region=#{env['S3_REGION']}\n手动备份清单：请按对象存储既有流程完成 bucket 快照/加锁。\n")
        puts "  已写入保护清单 #{step[:manifest]}（对象备份需手动处理）"
      when 'env-and-keys'
        FileUtils.mkdir_p(step[:dest_dir])
        step[:copy_targets].each do |t|
          next unless t && File.exist?(t)

          dest = File.join(step[:dest_dir], File.basename(t))
          FileUtils.cp_r(t, dest)
          File.chmod(0o600, dest)
          puts "  复制 #{t} -> #{dest} (chmod 600)"
        end
      when 'account-baseline'
        if rails_available?
          snapshot = account_baseline(step[:account])
          File.write(File.join(opts[:out], 'account_baseline.json'), JSON.pretty_generate(snapshot))
          puts '  基线快照已写入 account_baseline.json'
        else
          puts '  非 Rails 环境：跳过基线快照（请在实例上单独执行）'
        end
      end
    rescue StandardError => e
      raise "步骤 #{step[:name]} 失败: #{e.message}"
    end

    # 需 Rails（实例侧执行）；只读
    def account_baseline(username)
      account = Account.find_local(username) rescue nil
      raise "未找到本地账号 #{username}" if account.nil?

      {
        'account' => username,
        'taken_at_utc' => Time.now.utc.iso8601,
        'statuses_count' => account.statuses_count,
        'last_status_at' => account.last_status_at&.iso8601,
        'media_attachments_count' => (account.media_attachments.count rescue nil),
        'media_bytes' => (account.media_attachments.sum(:file_file_size) rescue nil),
        'following_count' => account.following_count,
        'followers_count' => account.followers_count
      }
    end

    def confirm(question)
      print "#{question} [y/N] "
      $stdout.flush
      answer = $stdin.gets
      answer&.strip&.casecmp('y')&.zero? == true
    end

    def parse(argv)
      opts = DEFAULTS.dup
      parser = OptionParser.new do |o|
        o.banner = '用法: 在实例上以 rails runner 加载本模块后调用（批次 B 接线；本批次仅 dry-run 演示）'
        o.on('--out DIR', "备份输出目录（默认 #{DEFAULTS[:out]}）") { |v| opts[:out] = v }
        o.on('--media-path PATH', '媒体目录（默认 ENV PAPERCLIP_ROOT_PATH / public/system）') { |v| opts[:media_path] = v }
        o.on('--env-file PATH', "Mastodon env 文件（默认 #{DEFAULTS[:env_file]}）") { |v| opts[:env_file] = v }
        o.on('--keys-dir DIR', '密钥目录（如存在）') { |v| opts[:keys_dir] = v }
        o.on('--account USER', '基线快照目标账号') { |v| opts[:account] = v }
        o.on('--execute', '真实执行（默认 dry-run）') { opts[:execute] = true }
        o.on('--yes', '跳过逐项确认（危险，仅在隔离演练环境用）') { opts[:yes] = true }
      end
      parser.parse(argv)
      opts
    end
  end
end
