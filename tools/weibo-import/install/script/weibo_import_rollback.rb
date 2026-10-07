#!/usr/bin/env ruby
# frozen_string_literal: true

# 薄入口：委托 weibo_import/rollback.rb（批次 B 实装；当前为占位）。
require_relative 'weibo_import/rollback'

exit WeiboImport::Rollback.run(ARGV)
