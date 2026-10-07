# frozen_string_literal: true

require 'weibo_import/silence'

class SilenceTest < Minitest::Test
  # 用独立假类验证抑制机制（不依赖 Mastodon 常量；真实类名在 apply! 内
  # 经 safe_const_get 找不到时记 class-missing，机制路径在假类上得到覆盖）
  class FakeWebhookWorker
    def self.perform_async(*_args)
      :enqueued
    end
  end

  def teardown
    # 恢复假类原方法
    FakeWebhookWorker.define_singleton_method(:perform_async) { |*| :enqueued }
    WeiboImport::Silence.reset_for_test!
  end

  def test_targets_declared_with_reasons
    assert WeiboImport::Silence::SUPPRESSED_TARGETS.length >= 4
    WeiboImport::Silence::SUPPRESSED_TARGETS.each do |type, _const, method, reason|
      assert %w[worker tracker].include?(type)
      refute_empty reason
      assert_equal 'perform_async', method unless type == 'tracker'
    end
  end

  def test_apply_is_idempotent_and_records
    WeiboImport::Silence.apply!
    before = WeiboImport::Silence.audit.length
    WeiboImport::Silence.apply!
    assert_equal before, WeiboImport::Silence.audit.length
    assert WeiboImport::Silence.applied?
  end

  def test_missing_class_recorded_not_raised
    WeiboImport::Silence.apply!
    missing = WeiboImport::Silence.audit.select { |e| e['action'] == 'class-missing' }
    # 本机无 Rails：4 个目标全部应为 class-missing（不抛异常）
    assert_equal 4, missing.length
    assert_includes WeiboImport::Silence.audit_report, '类不存在'
  end

  def test_suppression_mechanism_on_fake_class
    WeiboImport::Silence.send(:suppress_target, FakeWebhookWorker, 'FakeWebhookWorker', 'perform_async', '测试抑制')
    assert_nil FakeWebhookWorker.perform_async('status.created', 'Status', 1) # 原本返回 :enqueued
    calls = WeiboImport::Silence.audit.count { |e| e['action'] == 'suppressed-call' }
    assert_equal 1, calls
    assert_includes WeiboImport::Silence.audit_report, 'FakeWebhookWorker#perform_async: 拦截 1 次'
  end
end
