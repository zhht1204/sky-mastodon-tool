# frozen_string_literal: true

require 'weibo_import/verify'
require 'weibo_import/rollback'

class VerifyRollbackTest < Minitest::Test
  # check_threads / find_new_interactions 依赖 Rails 模型，集成阶段在实例上验证；
  # 这里覆盖纯报告与守卫逻辑。

  def ledger_row(state: 'imported', segment_no: 0, status_id: 100, media: [])
    { 'id' => 1, 'batch' => 'pilot-001', 'state' => state, 'segment_no' => segment_no,
      'status_id' => status_id, 'media_attachment_ids' => JSON.generate(media) }
  end

  def test_rollback_dry_run_report_shape
    rows = [ledger_row, ledger_row(segment_no: 1, status_id: 101, media: [7, 8])]
    text = WeiboImport::Rollback.dry_run_report(rows, [])
    assert_includes text, 'rollback dry-run'
    assert_includes text, '将删除帖子 : 2'
    assert_includes text, '将删除媒体 : 2'
    assert_includes text, '新互动检查 : 0 条'
  end

  def test_rollback_dry_run_reports_interactions_warning
    text = WeiboImport::Rollback.dry_run_report([ledger_row], [{ 'type' => 'favourite' }])
    assert_includes text, '新互动检查 : 1 条（真实回滚默认停止，需 --force）'
  end

  def test_verify_report_marks_fail
    account = Minitest::Mock.new
    account.expect :statuses_count, 3
    account.expect :last_status_at, nil
    rows = [ledger_row, ledger_row(state: 'partial')]
    results = [{ ok: true }, { ok: true }]
    text = WeiboImport::Verify.report(rows, results, [], account)
    assert_includes text, 'imported=1 partial=1'
    assert_includes text, 'PASS'
    account.verify
  end

  def test_verify_report_fail_when_failures
    account = Minitest::Mock.new
    account.expect :statuses_count, 0
    account.expect :last_status_at, nil
    rows = [ledger_row]
    results = [{ ok: false, reason: 'x' }]
    text = WeiboImport::Verify.report(rows, results, results, account)
    assert_includes text, 'FAIL'
    account.verify
  end
end
