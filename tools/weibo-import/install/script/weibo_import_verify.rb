#!/usr/bin/env ruby
# frozen_string_literal: true

# 薄入口：委托 weibo_import/verify.rb（批次 B 实装；当前为占位）。
require_relative 'weibo_import/verify'

exit WeiboImport::Verify.run(ARGV)
