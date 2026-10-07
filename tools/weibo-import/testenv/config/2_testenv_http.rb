# testenv 专用：以 RAILS_ENV=production 运行但走纯 HTTP（本实例无 TLS，仅绑 127.0.0.1）
# 文件名 2_ 前缀保证在 1_hosts.rb 之后、content_security_policy.rb 之前加载。
# 仅通过 compose mount 注入测试容器，绝不部署到生产实例。
Rails.application.configure do
  config.force_ssl = false
  config.x.use_https = false
  config.x.streaming_api_base_url = 'ws://127.0.0.1:46500'

  opts = config.action_mailer.default_url_options
  opts[:protocol] = 'http://' if opts.is_a?(Hash)
end
