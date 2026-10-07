# frozen_string_literal: true

# sky-mastodon-tool 顶层任务：test / lint / install
require 'rbconfig'

REPO_ROOT = File.expand_path(__dir__)
TOOL_DIR = File.join(REPO_ROOT, 'tools', 'weibo-import')

desc '运行 weibo-import 单元测试（minitest，纯逻辑，不需要 Rails/实例）'
task :test do
  Dir.chdir(TOOL_DIR) do
    sh RbConfig.ruby, 'tests/run_tests.rb' do |ok, _res|
      abort 'rake test: 单元测试失败' unless ok
    end
  end
end

desc '语法检查：install 树与 tests 逐文件 ruby -c'
task :lint do
  targets = Dir[File.join(TOOL_DIR, 'install', '**', '*.rb')] +
            Dir[File.join(TOOL_DIR, 'tests', '**', '*.rb')] +
            [File.join(REPO_ROOT, 'Rakefile')]
  abort 'rake lint: 未找到任何 Ruby 文件' if targets.empty?
  failed = []
  targets.sort.each do |f|
    # IO.popen 数组参数绕过 shell 引号问题（Windows 反斜杠路径经 cmd.exe 转义后会找不到文件，
    # 且错误输出按控制台码页返回非法 UTF-8，导致 .strip 崩溃）
    out = IO.popen([RbConfig.ruby, '-c', f], err: [:child, :out], &:read).to_s.strip
    rel = f.delete_prefix(REPO_ROOT + File::SEPARATOR)
    if $?.success? # rubocop:disable Style/SpecialGlobalVars
      puts "#{out} — #{rel}"
    else
      failed << rel
      puts "FAIL #{rel}\n#{out}"
    end
  end
  abort "rake lint: #{failed.size} 个文件语法错误: #{failed.join(', ')}" unless failed.empty?
end

desc '安装预演：调用 deploy/install.ps1（默认 dry-run；真复制需 -Execute）'
task :install do
  ps = File.join(REPO_ROOT, 'deploy', 'install.ps1')
  sh 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps
end

task default: %i[lint test]
