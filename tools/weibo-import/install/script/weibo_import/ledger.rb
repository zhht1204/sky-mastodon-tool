# frozen_string_literal: true

# 账本（批次 B 实装）。本批次只交付设计：表结构 DDL 常量 + 说明，
# **不执行任何 DDL、不创建任何表、不改 Mastodon 核心表**。
#
# 用途：幂等导入的事实来源。(account_id, source, source_id, segment_no) 唯一键
# 保证同一条来源微博的同一段不会被重复创建；state 记录 planned/imported/
# partial/failed/rolled_back，rollback 与 resume 都以账本为准。
#
# 创建方式：由 setup-ledger 子命令在批次 B 经人工确认后幂等创建
#（CREATE TABLE IF NOT EXISTS），绝不修改 Mastodon 核心表结构。

module WeiboImport
  module Ledger
    TABLE_NAME = 'sky_import_ledgers'
    STATES = %w[planned imported partial failed rolled_back].freeze
    SPLIT_STRATEGY_VERSION = 1 # splitter 逻辑版本；规则变更时递增

    # 与 Mastodon 现有 timestamp_id() 惯例一致（id 默认值走实例内的 PG 函数）；
    # 批次 B 校准点：确认实例存在 timestamp_id 函数及序列命名惯例后执行。
    DDL = <<~SQL
      CREATE TABLE IF NOT EXISTS sky_import_ledgers (
        id                       bigint PRIMARY KEY DEFAULT timestamp_id('sky_import_ledgers'::text),
        account_id               bigint NOT NULL,
        source                   text NOT NULL,
        source_id                text NOT NULL,
        split_strategy_version   integer NOT NULL,
        segment_no               integer NOT NULL DEFAULT 0,
        normalized_hash          text NOT NULL,
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
      );
      CREATE INDEX IF NOT EXISTS idx_sky_import_ledgers_batch
        ON sky_import_ledgers (account_id, batch, state);
    SQL

    ADVISORY_LOCK_NOTE = <<~TEXT
      批次 B 导入时用 PG advisory lock 串行化（防止并发导入同一账号）：

        SELECT pg_advisory_lock(hashtext('sky_weibo_import:<account_id>'));
        -- 导入主体（逐条 upsert 账本 + 建 Status，同一事务或明确补偿）
        SELECT pg_advisory_unlock(hashtext('sky_weibo_import:<account_id>'));

      注意：
      1) Rails 连接池下 lock/unlock 必须落在同一连接（如 ActiveRecord::Base.connection 原生执行，
         并在 ensure 中 unlock），否则可能出现悬挂锁。
      2) 设置 statement_timeout 与最长持锁时间上限；批次结束（含异常）必须释放。
      3) 会话级 advisory lock 在连接断开时自动释放，是较安全的默认选择。
    TEXT

    module_function

    def ddl
      DDL
    end

    def setup!(**_options)
      raise 'setup-ledger 为批次 B 交付：本批次不创建任何数据库对象（设计见 WeiboImport::Ledger::DDL）'
    end
  end
end
