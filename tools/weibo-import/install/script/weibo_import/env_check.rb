# frozen_string_literal: true

# 环境检查（只在目标实例的 Rails 环境只读运行；本批次交付代码，开发机不执行 Rails 部分）。
#
# 运行方式（实例侧）：
#   bin/rails runner script/weibo_import.rb env-check --account <本地账号>
#   或 docker compose exec（见 deploy/compose-usage.md，服务名/路径按实例实际值替换）
#
# 原则：只读；绝不打印密码/令牌/密钥明文——密钥类只显示「存在性 + SHA-256 指纹前 8 位」。
require 'digest'

module WeiboImport
  module EnvCheck
    ASSUMED_VERSION = '4.6.2'
    # Snowflake 源码在不同版本的位置不同：4.x 之前在 app/lib，较新版本移到 lib/
    KNOWN_SNOWFLAKE_PATHS = %w[
      app/lib/mastodon/snowflake.rb
      lib/mastodon/snowflake.rb
    ].freeze

    module_function

    # ---- 纯逻辑辅助（单测覆盖，不依赖 Rails）------------------------------------

    # 密钥显示：未设置 / 已设置 + 指纹
    def secret_fingerprint(value)
      return '(未设置)' if value.nil? || value.to_s.strip.empty?

      "已设置(sha256:#{Digest::SHA256.hexdigest(value.to_s)[0, 8]})"
    end

    # DSN 掩码：隐藏 :password@ 或 password= 部分
    def mask_dsn(dsn)
      s = dsn.to_s
      s = s.gsub(/:\/\/([^:\/\s]+):([^@\/\s]+)@/) { "://#{Regexp.last_match(1)}:***@" }
      s.gsub(/([?&]password=)[^&\s]*/i) { "#{Regexp.last_match(1)}***" }
    end

    # 与任务书假设（4.6.2）的差异清单
    def diff_against_assumption(facts)
      diffs = []
      version = facts['version'].to_s
      unless version.empty? || version.start_with?(ASSUMED_VERSION)
        diffs << "版本差异: 实测 #{version.inspect} vs 假设 #{ASSUMED_VERSION.inspect}——Snowflake/字符计数/回调位置一律以实测为准"
      end
      diffs << '未取得 Mastodon 版本号——必须先补齐（源码常量校准依赖它）' if version.empty?
      diffs << '未取得 git commit——历史版本可能与上游 main 有差异，Snowflake 常量必须读部署源码' if facts['git_commit'].to_s.empty?
      diffs << "存储模式差异: #{facts['storage_mode']}" if facts['storage_mode'].to_s.start_with?('s3')
      diffs << 'OpenSearch/ES 已启用——搜索索引副作用需纳入静默审计清单' if facts['search_enabled']
      diffs << 'FASP 相关配置存在——内容生命周期公告必须纳入静默审计清单' if facts['fasp_present']
      diffs << '账号不可用或未按预期（停用/封禁/禁言/未找到）——导入前必须解决' if facts['account_state'] && facts['account_state'] != 'ok' && facts['account_state'] != 'not_checked'
      diffs
    end

    # ---- Rails 侧（只在实例上执行）-----------------------------------------------

    def rails_available?
      defined?(Rails) && Rails.respond_to?(:root)
    end

    def run(account: nil, out: $stdout)
      unless rails_available?
        $stderr.puts 'env-check 需要在 Mastodon 实例的 Rails 环境运行（rails runner 或 docker compose exec，模板见 deploy/compose-usage.md）。'
        $stderr.puts '开发机/本批次红线：不访问任何生产实例。'
        return 1
      end

      facts = gather_facts(account)
      out.puts render_report(facts)
      0
    rescue StandardError => e
      $stderr.puts "env-check 失败: #{e.class}: #{e.message}"
      1
    end

    def gather_facts(account)
      facts = {}
      facts['version'] = (Mastodon::Version.to_s rescue '(不可得)')
      facts['git_commit'] = detect_git_commit
      facts['deployment_clues'] = detect_deployment
      facts['rails_entry'] = "#{$PROGRAM_NAME} (RAILS_ENV=#{ENV.fetch('RAILS_ENV', '(未设)')})"
      facts['db'] = db_facts
      facts['redis'] = redis_facts
      facts['storage_mode'] = storage_facts
      facts['search_enabled'] = search_facts
      facts['fasp_present'] = env_key_present?(/FASP/i)
      facts['webhooks_enabled'] = webhooks_facts
      facts['account_state'] = 'not_checked'
      facts.merge!(account_facts(account)) if account
      facts
    end

    def detect_git_commit
      rev = File.read(Rails.root.join('REVISION')).strip rescue nil
      return rev if rev

      head = File.read(Rails.root.join('.git', 'HEAD')).strip rescue nil
      return head if head

      '(不可得)'
    end

    def detect_deployment
      clues = []
      clues << '容器标志 /.dockerenv 存在' if File.exist?('/.dockerenv')
      clues << "ENV['RunningInDocker']=#{ENV['RunningInDocker'].inspect}" if ENV['RunningInDocker']
      clues << "ENV['DYNO'] 存在（托管平台）" if ENV['DYNO']
      root = Rails.root.to_s
      clues << "Rails.root=#{root}"
      clues << 'Dockerfile 存在于应用根' if File.exist?(Rails.root.join('Dockerfile'))
      clues.empty? ? "(无明显线索 Rails.root=#{root})" : clues.join('；')
    end

    def db_facts
      cfg = ActiveRecord::Base.connection_db_config.configuration_hash rescue {}
      {
        'adapter' => cfg[:adapter] || cfg['adapter'] || '(不可得)',
        'host' => cfg[:host] || cfg['host'] || '(不可得)',
        'port' => cfg[:port] || cfg['port'] || '(不可得)',
        'database' => cfg[:database] || cfg['database'] || '(不可得)',
        'user' => cfg[:username] || cfg['username'] || '(不可得)',
        'password' => secret_fingerprint(cfg[:password] || cfg['password'])
      }
    end

    def redis_facts
      url = ENV['REDIS_URL'].presence || [ENV['REDIS_HOST'], ENV['REDIS_PORT']].compact.join(':')
      { 'url' => url.to_s.empty? ? '(未配置)' : mask_dsn(url), 'password' => secret_fingerprint(ENV['REDIS_PASSWORD']) }
    end

    def storage_facts
      if ENV['S3_ENABLED'].to_s.casecmp('true').zero?
        "S3（bucket=#{ENV['S3_BUCKET'] || ENV['S3_BUCKET_NAME'] || '(未配置)'}，region=#{ENV['S3_REGION'] || '(未配置)'}；密钥只显示指纹: #{secret_fingerprint(ENV['AWS_SECRET_ACCESS_KEY'])}）"
      else
        "本地文件系统（候选路径: #{ENV['PAPERCLIP_ROOT_PATH'] || Rails.root.join('public', 'system')}）"
      end
    end

    def search_facts
      ENV['ES_ENABLED'].to_s.casecmp('true').zero? || ENV['OPENSEARCH_ENABLED'].to_s.casecmp('true').zero?
    end

    def webhooks_facts
      begin
        return 'Webhook 表不可读（跳过）' unless defined?(Admin::Webhook) && ActiveRecord::Base.connection.table_exists?('webhooks')

        "Admin::Webhook 记录数: #{Admin::Webhook.count}"
      rescue StandardError
        'Webhook 状态不可得（跳过）'
      end
    end

    def env_key_present?(pattern)
      ENV.keys.any? { |k| k.match?(pattern) }
    end

    def account_facts(username)
      account = Account.find_local(username) rescue nil
      return { 'account_state' => "未找到本地账号 #{username.inspect}" } if account.nil?

      state = []
      state << '停用(disabled)' if account.user&.disabled
      state << '封禁(suspended)' if account.suspended?
      state << '禁言(silenced)' if account.silenced?
      {
        'account_state' => state.empty? ? 'ok' : state.join('；'),
        'account_local' => account.local?,
        'account_statuses_count' => account.statuses_count,
        'account_last_status_at' => account.last_status_at&.iso8601 || '(从未发帖)',
        'account_media_usage_bytes' => (account.media_attachments.sum(:file_file_size) rescue '(不可得)')
      }
    end

    # Snowflake 源码审计提示：反射定位 + 源码行级搜索，供批次 B 校准 id_allocator
    def snowflake_audit_hints
      lines = []
      if defined?(Mastodon::Snowflake)
        %i[id_at to_time].each do |m|
          loc = (Mastodon::Snowflake.respond_to?(m) ? Mastodon::Snowflake.method(m).source_location : nil) rescue nil
          lines << "反射: Mastodon::Snowflake.#{m} 定义于 #{loc ? loc.join(':') : '(不可得)'}"
        end
        if defined?(Mastodon::Snowflake::Callbacks)
          loc = (Mastodon::Snowflake::Callbacks.method(:around_create).source_location rescue nil)
          lines << "反射: Snowflake::Callbacks.around_create（含 created_at==updated_at 判断）定义于 #{loc ? loc.join(':') : '(不可得)'}"
        end
      else
        lines << '警告: 未加载到 Mastodon::Snowflake 常量'
      end

      KNOWN_SNOWFLAKE_PATHS.each do |rel|
        f = Rails.root.join(rel)
        next unless File.exist?(f)

        lines << "源码扫描: #{rel}"
        File.foreach(f).with_index(1) do |line, no|
          lines << "  #{rel}:#{no}: #{line.strip}" if line.match?(/created_at|updated_at|<<\s*16|TIMESTAMP|sequence/i)
        end
      end
      status_rb = Rails.root.join('app', 'models', 'status.rb')
      if File.exist?(status_rb)
        lines << '源码扫描: app/models/status.rb（id/时间戳相关行）'
        File.foreach(status_rb).with_index(1) do |line, no|
          lines << "  app/models/status.rb:#{no}: #{line.strip}" if line.match?(/Snowflake|created_at|override_timestamps/i)
        end
      end
      lines
    end

    def render_report(facts)
      diffs = diff_against_assumption(facts)
      <<~TEXT
        # weibo-import 环境检查报告（只读）

        ## 基础
        - Mastodon 版本: #{facts['version']}   git commit: #{facts['git_commit']}
        - 部署方式线索: #{facts['deployment_clues']}
        - Rails 入口: #{facts['rails_entry']}

        ## 数据与缓存（密码/密钥只显示存在性+指纹）
        - DB: #{facts['db']['adapter']} #{facts['db']['host']}:#{facts['db']['port']}/#{facts['db']['database']} user=#{facts['db']['user']} password=#{facts['db']['password']}
        - Redis: #{facts['redis']['url']} password=#{facts['redis']['password']}
        - 媒体存储: #{facts['storage_mode']}
        - 搜索（ES/OpenSearch）: #{facts['search_enabled'] ? '启用' : '未启用'}
        - FASP 配置: #{facts['fasp_present'] ? '存在（需静默审计）' : '未发现'}
        - Webhook: #{facts['webhooks_enabled']}

        ## 目标账号
        - 状态: #{facts['account_state']}
        - 本地账号: #{facts['account_local']}   statuses_count: #{facts['account_statuses_count']}   last_status_at: #{facts['account_last_status_at']}
        - 媒体用量估算（字节）: #{facts['account_media_usage_bytes']}

        ## 与任务书假设（#{ASSUMED_VERSION}）的差异清单
        #{diffs.empty? ? '（未发现差异）' : diffs.map { |d| "- #{d}" }.join("\n")}

        ## Snowflake 源码审计提示（批次 B 校准 id_allocator 用）
        #{snowflake_audit_hints.empty? ? '（本环境无法执行反射/源码扫描——请确认在 rails runner 内运行）' : snowflake_audit_hints.join("\n")}

        > 本报告只读，未对实例做任何写操作；未输出任何明文密钥。
      TEXT
    end
  end
end
