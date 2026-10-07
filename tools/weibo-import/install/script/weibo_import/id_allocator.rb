# frozen_string_literal: true

# 历史 Snowflake ID 分配（纯逻辑 + 单测；批次 B 在实例上校准）。
#
# 参考：mastodon/mastodon lib/mastodon/snowflake.rb（上游 main，2026-10 抓取）：
#   id = (unix_ms << 16) | sequence16     # 48bit 毫秒时间位 + 16bit 序列位
#   Mastodon::Snowflake.id_at(timestamp, with_random: true) 给毫秒与序列各加随机量
#   Callbacks.around_create 中「created_at == updated_at」的判断决定是否走 id_at 回填
#
# 注意：用户实例标称 4.6.2，但一切以 env_check 抓取的实际部署源码为准；
# 下方常量可被 env_check 的输出覆盖（批次 B 校准流程见 docs/weibo-import.md）。
#
# 红线：绝不为了排序人为增减 created_at。ID 时间位取来源 UTC 毫秒；
# 仅当下一条请求的毫秒早于已分配毫秒时，把 ID 时间位钳制到 last_ms（created_at 不动），
# 以保证「父帖 ID < 子帖 ID」。
module WeiboImport
  module IdAllocator
    TIMESTAMP_SHIFT = 16
    SEQUENCE_BITS = 16
    SEQUENCE_MASK = (1 << SEQUENCE_BITS) - 1

    class ExhaustedError < StandardError; end

    module_function

    def pack(unix_ms, sequence, shift: TIMESTAMP_SHIFT)
      (unix_ms.to_i << shift) | sequence
    end

    def unpack(id, shift: TIMESTAMP_SHIFT)
      [id >> shift, id & ((1 << shift) - 1)]
    end

    def id_to_time(id, shift: TIMESTAMP_SHIFT)
      ms, = unpack(id, shift: shift)
      Time.at(ms / 1000.0).utc
    end

    # 冲突检测接口：批次 B 配合 DB 唯一约束 / 既有 ID 集合使用
    def detect_collision?(ids)
      ids.length != ids.uniq.length
    end

    def collision_pairs(ids)
      ids.group_by(&:itself).select { |_, v| v.length > 1 }.keys
    end

    class Allocator
      attr_reader :last_id, :last_ms, :last_seq

      def initialize(timestamp_shift: IdAllocator::TIMESTAMP_SHIFT)
        @shift = timestamp_shift
        @seq_mask = (1 << @shift) - 1
        @last_id = nil
        @last_ms = nil
        @last_seq = nil
        @reserved = {} # { ms => { seq => true } }
      end

      # 分配一个 ID；同毫秒内序列严格递增，跨毫秒重置。
      # 请求毫秒早于 last_ms 时钳制到 last_ms（保证单调不减；created_at 不受影响）。
      def next_id_at(unix_ms)
        ms = unix_ms.to_i
        ms = @last_ms if @last_ms && ms < @last_ms
        seq = next_seq(ms)
        @last_ms = ms
        @last_seq = seq
        @last_id = IdAllocator.pack(ms, seq, shift: @shift)
      end

      # 登记既有 ID（批次 B 从 DB 载入），next_id_at 会跳过已占用的 (ms, seq)
      def reserve(existing_id)
        ms = existing_id >> @shift
        seq = existing_id & @seq_mask
        (@reserved[ms] ||= {})[seq] = true
        @last_ms = ms if @last_ms.nil? || ms > @last_ms
        update_last_seq(ms, seq)
        existing_id
      end

      private

      def update_last_seq(ms, seq)
        return unless @last_ms == ms

        @last_seq = seq if @last_seq.nil? || seq > @last_seq
      end

      def next_seq(ms)
        seq = @last_ms == ms ? (@last_seq || -1) + 1 : 0
        reserved_ms = @reserved[ms]
        seq += 1 while reserved_ms&.key?(seq)
        raise ExhaustedError, "同毫秒序列耗尽 (ms=#{ms})" if seq > @seq_mask

        seq
      end
    end
  end
end
