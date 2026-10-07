# sky-mastodon-tool

自托管 Mastodon 实例的单人运维工具仓：Ruby CLI（stdlib-only），无 Web 界面、无自有服务、无自有数据库，一切生产读写都发生在目标 Mastodon 实例上（`rails runner` / `docker compose exec`）。

当前工具：**weibo-import**（微博历史归档导入）— 操作手册见 [`tools/weibo-import/docs/weibo-import.md`](tools/weibo-import/docs/weibo-import.md)。

## 批次进度

| 批次 | 状态 | 范围 |
|---|---|---|
| A | **已交付** | CLI 骨架（`plan`/`env-check` 真实可用，`import`/`verify`/`rollback`/`setup-ledger` 占位）；`weibo_normalize.rb`（`inspect`/`map`/`normalize`/`fetch-media` 纯 Ruby 可独立运行）；splitter / id_allocator / ledger 设计 / backup 编排（dry-run）；minitest 单测与本地端到端演练。**无任何生产实例访问、无真实导入写入、无数据库表创建。** |
| B | **已交付**（隔离实例验证） | 实装 `import`/`verify`/`rollback`/`setup-ledger`、静默回调抑制（定向 no-op + 审计）、账本表（唯一约束 + advisory lock + UPSERT）、确定性历史 Snowflake ID（`override_timestamps` 显式 ID 已验证不被覆盖）。隔离实例（4.6.2）实测：试导入 20 条 → verify PASS → 幂等重跑 → 回滚 → 全量重建闭环；网页核验 2012 原时间线/转发引用/互动摘要/原文链接/图片正常。剩余：生产实例 env-check 校准 + 试导入验收（G4/G5 确认门）→ 批次 C。 |
| C | **已完成**（2026-10-07） | 生产全量导入：610 条微博 → **644 帖 + 224 媒体**（试导入 20 + 全量 624，批 prod-pilot-001 / prod-full-001）；双批次 verify PASS，statuses_count 81→725 精确，last_status_at 未回退，队列零任务，幂等重跑零新建；微博 ID → 帖子映射见 `tmp/import-map-prod-*.jsonl`（本机）与生产主机 `~/weibo-import/`（备份 `~/weibo-import/backups/20261007-174054/`：pg_dump 6.8MB + 配置 + 基线快照，恢复验证零错误）。 |

## 快速开始（Windows 开发机）

```powershell
rake lint        # install 树与 tests 逐文件 ruby -c
rake test        # weibo-import 全部单元测试

# 纯 Ruby 工具链（不需要实例）：
ruby tools/weibo-import/install/script/weibo_normalize.rb inspect --input <导出.json> --sample 20
ruby tools/weibo-import/install/script/weibo_normalize.rb map --from <候选映射.yml> --out config/field_map.yml
ruby tools/weibo-import/install/script/weibo_normalize.rb normalize --input <导出.json> --map config/field_map.yml --out normalized.jsonl --raw-dir raw_copy/
ruby tools/weibo-import/install/script/weibo_normalize.rb fetch-media --input normalized.jsonl --media-dir media/
ruby tools/weibo-import/install/script/weibo_import.rb plan --account <账号> --input normalized.jsonl
```

实例侧（env-check 等 Rails 依赖命令）：先 `rake install`（dry-run 预览）→ `deploy/install.ps1 -Execute` → 在实例上 `rails runner` / `docker compose exec` 执行，模板见 [`deploy/compose-usage.md`](deploy/compose-usage.md)。

隔离测试实例（批次 B，本机 Docker）：

```powershell
cd tools\weibo-import\testenv
powershell -ExecutionPolicy Bypass -File setup.ps1     # 一键初始化（幂等）
powershell -ExecutionPolicy Bypass -File teardown.ps1  # 用完销毁（down -v）
```

规范与例外见 [`AGENTS.md`](AGENTS.md)；仓库规则的上游事实来源是 [`../sky-guiding/AGENTS.md`](../sky-guiding/AGENTS.md)。
