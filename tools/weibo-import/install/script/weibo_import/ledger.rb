# frozen_string_literal: true

# 导入账本：幂等导入的事实来源（批次 B 实装）。
#
# 设计要点：
# - 独立辅助表 sky_import_ledgers，绝不修改 Mastodon 核心表结构；
#   id 默认值复用实例内已有的 timestamp_id() PG 函数（与 Mastodon 惯例一致）。
# - (account_id, source, source_id, segment_no) 唯一约束保证同一来源微博的同一段
#   不会被重复创建；status 创建与账本行写入在同一数据库事务内（崩溃不会产生
#   「有帖子无账本」的状态；媒体行在事务外创建，孤儿由 cleanup 处理）。
# - 会话级 PG advisory lock 串行化同一账号的导入进程。
#
# 本模块只在 Rails（rails runner）环境执行数据库操作；纯逻辑部分可单测。

module WeiboImport
  module Ledger
    TABLE_NAME = 'sky_import_ledgers'
    STATES = %w[planned imported partial failed rolled_back].freeze
    SPLIT_STRATEGY_VERSION = 1 # splitter 逻辑版本；规则变更时递增

    DDL_CREATE_TABLE = <<~SQL
      CREATE TABLE IF NOT EXISTS sky_import_ledgers (
        id                       bigint PRIMARY KEY DEFAULT timestamp_id('sky_import_ledgers'::text),
        account_id               bigint NOT NULL,
        source                   text NOT NULL,
        source_id                text NOT NULL,
        split_strategy_version   integer NOT NULL,
        segment_no               integer NOT NULL DEFAULT 0,
        normalized_hash          text NOT NULL,
        source_created_at        timestamptz NOT NULL,
        visibility               text NOT NULL,
        batch                    text NOT NULL,
        status_id                bigint,
        media_attachment_ids     jsonb NOT NULL DEFAULT '[]'::jsonb,
        state                    text NOT NULL DEFAULT 'planned',
        error                    text,
        created_at               timestamptz NOT NULL DEFAULT now(),
        updated_at               timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT sky_import_ledgers_state_chk
          CHECK (state IN ('planned', 'imported', 'partial', 'failed', 'rolled_back')),
        CONSTRAINT sky_import_ledgers_source_uniq
          UNIQUE (account_id, source, source_id, segment_no)
      )
    SQL

    DDL_INDEX_BATCH = <<~SQL
      CREATE INDEX IF NOT EXISTS idx_sky_import_ledgers_batch
        ON sky_import_ledgers (account_id, batch, state)
    SQL

    DDL_INDEX_STATUS = <<~SQL
      CREATE INDEX IF NOT EXISTS idx_sky_import_ledgers_status
        ON sky_import_ledgers (status_id) WHERE status_id IS NOT NULL
    SQL

    # timestamp_id() 的序列默认只对 Mastodon 自有表存在（其迁移里建）；
    # 账本表用同一默认值就必须自己幂等补建序列（写法对齐 Mastodon 的 ensure_id_sequences_exist）
    DDL_SEQUENCE = <<~SQL
      DO $$
        BEGIN
          CREATE SEQUENCE sky_import_ledgers_id_seq;
        EXCEPTION WHEN duplicate_table THEN
          NULL;
        END
      $$ LANGUAGE plpgsql
    SQL

    DDL_STATEMENTS = [DDL_CREATE_TABLE, DDL_INDEX_BATCH, DDL_INDEX_STATUS, DDL_SEQUENCE].freeze

    LOCK_NAMESPACE = 'sky_weibo_import'

    module_function

    def ddl
      DDL_STATEMENTS.join(";\n")
    end

    # 幂等建表（setup-ledger 子命令调用；须在确认门后执行）
    # 返回 { created: bool, already_existed: bool }
    def setup!(connection)
      existed = exists?(connection)
      DDL_STATEMENTS.each { |stmt| connection.execute(stmt) }
      { created: !existed, already_existed: existed }
    end

    def exists?(connection)
      connection.select_value(
        "SELECT EXISTS (SELECT 1 FROM pg_class WHERE relname = '#{TABLE_NAME}')::int"
      ).to_i == 1
    end

    # ---- 会话级 advisory lock（同账号串行；导入全程持锁，ensure 释放）----

    def lock_key(account_id)
      "#{LOCK_NAMESPACE}:#{account_id}"
    end

    # 尝试在 timeout_seconds 内获取锁；拿不到返回 false（调用方应中止而非阻塞等待）
    def acquire_lock!(connection, account_id, timeout_seconds: 60)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      key = lock_key(account_id)
      loop do
        got = connection.select_value(
          "SELECT pg_try_advisory_lock(hashtext('#{key}'))::int"
        ).to_i == 1
        return true if got
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 1
      end
    end

    def release_lock!(connection, account_id)
      connection.execute("SELECT pg_advisory_unlock(hashtext('#{lock_key(account_id)}'))")
    rescue StandardError
      # 连接已断开时锁随会话自动释放
      nil
    end

    # ---- 行操作（raw SQL，避免向 Mastodon 应用注入 AR 模型）----

    def rows_for(connection, account_id, source, source_id)
      connection.select_all(<<~SQL.squish).to_a
        SELECT * FROM #{TABLE_NAME}
        WHERE account_id = #{account_id.to_i}
          AND source = #{connection.quote(source)}
          AND source_id = #{connection.quote(source_id)}
        ORDER BY segment_no
      SQL
    end

    def imported_source_ids(connection, account_id, source)
      connection.select_all(<<~SQL.squish).to_a
        SELECT source_id,
               COUNT(*) AS segments,
               COUNT(*) FILTER (WHERE state = 'imported') AS imported_segments,
               COUNT(*) FILTER (WHERE state = 'partial')  AS partial_segments,
               COUNT(*) FILTER (WHERE state = 'failed')   AS failed_segments,
               MAX(normalized_hash) AS normalized_hash
        FROM #{TABLE_NAME}
        WHERE account_id = #{account_id.to_i} AND source = #{connection.quote(source)}
        GROUP BY source_id
      SQL
    end

    def batch_rows(connection, account_id, batch)
      connection.select_all(<<~SQL.squish).to_a
        SELECT * FROM #{TABLE_NAME}
        WHERE account_id = #{account_id.to_i} AND batch = #{connection.quote(batch)}
        ORDER BY source_created_at, segment_no
      SQL
    end

    # 同事务写入一行（由 importer 在 Status 创建的同一事务内调用）。
    # UPSERT：回滚后重新导入时复用既有行（唯一键命中则刷新为新 status_id/状态）；
    # 非 rolled_back 命中由 importer 的 precheck 提前拦截，不会走到这里。
    # attrs: account_id/source/source_id/segment_no/normalized_hash/source_created_at/
    #        visibility/batch/status_id/media_attachment_ids/state
    def insert_row!(connection, attrs)
      connection.execute(<<~SQL.squish)
        INSERT INTO #{TABLE_NAME}
          (account_id, source, source_id, split_strategy_version, segment_no,
           normalized_hash, source_created_at, visibility, batch,
           status_id, media_attachment_ids, state, error)
        VALUES
          (#{attrs.fetch(:account_id).to_i},
           #{connection.quote(attrs.fetch(:source))},
           #{connection.quote(attrs.fetch(:source_id))},
           #{SPLIT_STRATEGY_VERSION},
           #{attrs.fetch(:segment_no).to_i},
           #{connection.quote(attrs.fetch(:normalized_hash))},
           #{connection.quote(attrs.fetch(:source_created_at))},
           #{connection.quote(attrs.fetch(:visibility))},
           #{connection.quote(attrs.fetch(:batch))},
           #{attrs[:status_id].to_i},
           #{connection.quote(JSON.generate(attrs.fetch(:media_attachment_ids, [])))}::jsonb,
           #{connection.quote(attrs.fetch(:state, 'imported'))},
           #{attrs[:error] ? connection.quote(attrs[:error][0, 2000]) : 'NULL'})
        ON CONFLICT (account_id, source, source_id, segment_no) DO UPDATE SET
          normalized_hash = EXCLUDED.normalized_hash,
          source_created_at = EXCLUDED.source_created_at,
          visibility = EXCLUDED.visibility,
          batch = EXCLUDED.batch,
          status_id = EXCLUDED.status_id,
          media_attachment_ids = EXCLUDED.media_attachment_ids,
          state = EXCLUDED.state,
          error = EXCLUDED.error,
          updated_at = now()
      SQL
    end

    def mark_rolled_back!(connection, row_id)
      connection.execute(<<~SQL.squish)
        UPDATE #{TABLE_NAME}
        SET state = 'rolled_back', status_id = NULL, updated_at = now()
        WHERE id = #{row_id.to_i}
      SQL
    end

    # 孤儿媒体行（status_id 为空且创建于某时刻之后）——崩溃恢复/清理用
    def orphan_media_since(connection, account_id, since_iso8601)
      connection.select_all(<<~SQL.squish).to_a
        SELECT id FROM media_attachments
        WHERE account_id = #{account_id.to_i}
          AND status_id IS NULL
          AND created_at >= #{connection.quote(since_iso8601)}
        ORDER BY id
      SQL
    end
  end
end
