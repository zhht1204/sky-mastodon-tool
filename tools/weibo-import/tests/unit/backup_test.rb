# frozen_string_literal: true

require 'weibo_import/backup'

class BackupTest < Minitest::Test
  B = WeiboImport::Backup

  ENV_OK = { 'DB_HOST' => 'db.local', 'DB_PORT' => '5432', 'DB_NAME' => 'mastodon', 'DB_USER' => 'mastodon', 'DB_PASS' => 's3cret' }.freeze

  def test_pg_dump_command_shape_and_no_password_in_argv
    cmd = B.pg_dump_command(ENV_OK, '/backups/dump.sql')
    assert_includes cmd, "-d 'mastodon'"
    assert_includes cmd, "-h 'db.local'"
    assert_includes cmd, "-U 'mastodon'"
    assert_includes cmd, '-f'
    refute_includes cmd, 's3cret' # 密码绝不进命令行
    assert_includes cmd, '--no-owner --no-privileges'
  end

  def test_pg_dump_command_requires_db_name
    assert_raises(ArgumentError) { B.pg_dump_command({ 'DB_HOST' => 'x' }, '/out.sql') }
  end

  def test_pg_env_carries_password_via_env_only
    assert_equal({ 'PGPASSWORD' => 's3cret' }, B.pg_env(ENV_OK))
    assert_equal({ 'PGPASSWORD' => nil }, B.pg_env({}))
  end

  def test_mask_command
    assert_equal 'PGPASSWORD=***', B.mask_command('PGPASSWORD=hunter2')
    cmd = B.pg_dump_command(ENV_OK, '/x.sql')
    assert_equal cmd, B.mask_command(cmd) # 命令本身无密码则原样
  end

  def test_tar_command_and_shq
    cmd = B.tar_command('/var/mastodon/public/system', '/backups/m.tar.gz')
    assert_includes cmd, "tar -czf '/backups/m.tar.gz' -C '/var/mastodon/public' 'system'"
    assert_raises(ArgumentError) { B.tar_command('  ', '/x.tar.gz') }
    assert_equal "'a'\\''b'", B.shq("a'b") # 单引号安全转义
  end
end
