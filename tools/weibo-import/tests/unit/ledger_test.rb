# frozen_string_literal: true

require 'weibo_import/ledger'

class LedgerTest < Minitest::Test
  L = WeiboImport::Ledger

  def test_ddl_has_unique_constraint_and_check
    ddl = L.ddl
    assert_includes ddl, 'UNIQUE (account_id, source, source_id, segment_no)'
    L::STATES.each { |s| assert_includes ddl, "'#{s}'" }
    assert_includes ddl, 'timestamp_id(' # id 默认值复用实例 PG 函数
    assert_includes ddl, 'CREATE TABLE IF NOT EXISTS' # 幂等
    assert_includes ddl, 'CREATE SEQUENCE sky_import_ledgers_id_seq' # timestamp_id 依赖序列
  end

  def test_ddl_records_verification_columns
    ddl = L.ddl
    assert_includes ddl, 'source_created_at'
    assert_includes ddl, 'visibility'
    assert_match(/media_attachment_ids\s+jsonb/, ddl)
  end

  def test_lock_key_namespaced_per_account
    assert_equal 'sky_weibo_import:42', L.lock_key(42)
    refute_equal L.lock_key(1), L.lock_key(2)
  end

  def test_states_complete_for_workflow
    assert_equal %w[planned imported partial failed rolled_back], L::STATES
  end

  def test_split_strategy_version_pinned
    assert_kind_of Integer, L::SPLIT_STRATEGY_VERSION
  end
end
