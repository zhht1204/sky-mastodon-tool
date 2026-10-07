#!/usr/bin/env ruby
# frozen_string_literal: true

# 薄入口：委托 weibo_import/verify.rb（需在 Mastodon rails runner 环境执行）。
require_relative 'weibo_import/cli'
require_relative 'weibo_import/verify'

cli = WeiboImport::CLI.new
begin
  cli.parse(ARGV)
rescue WeiboImport::CLI::ParseFailure => e
  $stderr.puts "参数错误: #{e.message}"
  exit 64
end
exit WeiboImport::Verify.run(cli)
