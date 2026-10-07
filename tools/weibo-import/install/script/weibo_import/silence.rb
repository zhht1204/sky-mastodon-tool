# frozen_string_literal: true

# 静默回调抑制（批次 B 实装）——只在本次 rails runner 进程内生效。
#
# 依据部署源码（4.6.2）逐项核实的 Status 创建回调：
#   after_create_commit :trigger_create_webhooks      → TriggerWebhookWorker.perform_async  【抑制】
#   Status::FaspConcern announce_new/updated_content  → 仅 public_visibility?（我们 unlisted，天然跳过）【审计】
#   Status::FaspConcern announce_trends               → 对 reply 生效（只查 account_indexable?）【抑制】
#   after_create_commit :update_statistics            → ActivityTracker.increment（Redis 实时活跃度）【抑制】
#   after_create_commit :increment_counter_caches     → statuses_count/last_status_at/replies_count【保留】
#   after_create_commit :store_uri, if: :local?       → 本地 URI 生成【保留】
#   before_validation :set_conversation + after_create :update_conversation → thread/conversation【保留】
#   MediaAttachment after_commit :enqueue_processing  → PostProcessMediaWorker（转码/缩略图）【保留】
#   Chewy update_index（statuses/public_statuses）    → ES 启用时入索引任务【保留】
#
# 红线：禁止全局禁用所有回调；禁止全局把 Sidekiq 入队改成空操作。
# 本模块只对「具体 worker 类 / ActivityTracker」做单例级定向 no-op，
# 并记录每次抑制到内存审计表，导入结束后输出（Silence.audit_report）。

module WeiboImport
  module Silence
    # [类型, 常量名, 方法, 抑制原因]
    SUPPRESSED_TARGETS = [
      ['worker', 'TriggerWebhookWorker', 'perform_async', 'Webhook 通知任务'],
      ['worker', 'Fasp::AnnounceContentLifecycleEventWorker', 'perform_async', 'FASP 内容生命周期公告'],
      ['worker', 'Fasp::AnnounceTrendWorker', 'perform_async', 'FASP 趋势公告（reply 也会触发）'],
      ['tracker', 'ActivityTracker', 'increment', '实时活跃度统计（update_statistics）']
    ].freeze

    @audit = []
    @applied = false

    class << self
      attr_reader :audit

      def applied?
        @applied
      end

      # 仅供测试：还原模块状态（不动被覆盖的类——那由测试自行恢复）
      def reset_for_test!
        @audit = []
        @applied = false
        self
      end

      # 定向抑制：仅本进程内、仅列出的类与方法。可重复调用幂等。
      def apply!
        return self if @applied

        SUPPRESSED_TARGETS.each do |type, const_name, method_name, reason|
          klass = safe_const_get(const_name)
          if klass.nil?
            audit << { 'target' => const_name, 'method' => method_name, 'action' => 'class-missing',
                       'reason' => "#{reason}（类不存在，实例未编译该功能）" }
            next
          end

          case type
          when 'worker'
            suppress_target(klass, const_name, method_name, reason)
          when 'tracker'
            suppress_target(klass, const_name, method_name, reason)
          end
        end
        @applied = true
        self
      end

      # 导入结束后的审计输出（抑制了什么、各拦截了多少次调用）
      def audit_report
        lines = ['== 静默回调审计 ==']
        grouped = audit.group_by { |e| "#{e['target']}##{e['method']}" }
        if grouped.empty?
          lines << '(无抑制记录)'
        else
          grouped.each do |key, entries|
            calls = entries.count { |e| e['action'] == 'suppressed-call' }
            setup = entries.find { |e| e['action'] != 'suppressed-call' }
            lines << "#{key}: 拦截 #{calls} 次调用（#{setup['reason']}）"
          end
        end
        lines.join("\n")
      end

      private

      def safe_const_get(name)
        Object.const_get(name)
      rescue NameError
        nil
      end

      # 单例级覆盖：仅本进程、仅该类的该方法；不触碰 Sidekiq 全局入队，不影响其他 worker
      def suppress_target(klass, const_name, method_name, reason)
        audit << { 'target' => const_name, 'method' => method_name, 'action' => 'suppressed', 'reason' => reason }
        klass.define_singleton_method(method_name) do |*args|
          (WeiboImport::Silence.audit << { 'target' => const_name, 'method' => method_name,
                                           'action' => 'suppressed-call', 'reason' => reason })
          nil
        end
      end
    end
  end
end
