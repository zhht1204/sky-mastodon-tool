# frozen_string_literal: true

# 单元测试统一入口：rake test 调用本文件（在 tools/weibo-import 目录下执行）。
# 纯逻辑测试：不访问网络、不写数据库、不依赖 Rails/实例。
require 'minitest/autorun'

SCRIPT_DIR = File.expand_path('../install/script', __dir__)
FIXTURES_DIR = File.expand_path('fixtures', __dir__)
$LOAD_PATH.unshift(SCRIPT_DIR) unless $LOAD_PATH.include?(SCRIPT_DIR)

Dir[File.expand_path('unit/*_test.rb', __dir__)].sort.each { |f| require f }
