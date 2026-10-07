# sky-mastodon-tool

自托管 Mastodon 实例的单人运维工具仓：Ruby CLI（stdlib-only），无 Web 界面、无自有服务、无自有数据库，一切生产读写都发生在目标 Mastodon 实例上（`rails runner` / `docker compose exec`）。

当前工具：**weibo-import**（微博历史归档导入）— 操作手册见 [`tools/weibo-import/docs/weibo-import.md`](tools/weibo-import/docs/weibo-import.md)。

## 批次进度

| 批次 | 状态 | 范围 |
|---|---|---|
| A | **已交付** | CLI 骨架（`plan`/`env-check` 真实可用，`import`/`verify`/`rollback`/`setup-ledger` 占位）；`weibo_normalize.rb`（`inspect`/`map`/`normalize`/`fetch-media` 纯 Ruby 可独立运行）；splitter / id_allocator / ledger 设计 / backup 编排（dry-run）；minitest 单测与本地端到端演练。**无任何生产实例访问、无真实导入写入、无数据库表创建。** |
| B | 待启动 | 前置条件：①隔离测试实例；②真实导出 JSON 样本；③在实例上实测 `env-check` 并按部署源码校准 Snowflake/字符计数常量。交付：`import`/`verify`/`rollback`/`setup-ledger`、静默回调抑制、账本实装、试导入 20 条验收。 |
| C | 待启动 | 全量导入与收尾：完整计数口径对账、回滚演练、批次归档。 |

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

规范与例外见 [`AGENTS.md`](AGENTS.md)；仓库规则的上游事实来源是 [`../sky-guiding/AGENTS.md`](../sky-guiding/AGENTS.md)。
