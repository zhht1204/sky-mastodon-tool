# sky-mastodon-tool

[English intro below](#english-intro)

面向自托管 [Mastodon](https://joinmastodon.org) 实例的**单人运维工具仓**。当前提供第一个工具 **weibo-import**：把微博 JSON 历史导出以**原始时间、静默、幂等、可验证、可回滚**的方式导入指定本地账号。

```text
微博导出 JSON ──inspect──▶ 字段映射 ──normalize──▶ normalized.jsonl ──plan──▶ 预演报告
                                    │                                      │
                              fetch-media（SSRF 安全下载）                    ▼
                                    └──────────────▶ import ──▶ verify / rollback
                                                 （账本 + 历史 Snowflake ID + 静默回调）
```

## weibo-import 解决什么问题

Mastodon 自带的导入功能只支持关注列表等数据，**不支持带原始时间的历史帖子归档**——用正常发帖 API 导入会把旧帖当成新帖推送给关注者。本工具在 Rails 模型层直接创建帖子，实现：

- **时间保真**：`created_at` 保留来源原始时间（含时区）；帖子 ID 使用对应历史时刻的 Snowflake ID，主页时间线排序与分页天然正确。
- **静默导入**：不触发时间线分发、提及通知、邮件、Webhook、FASP 公告与实时活跃度统计（进程内定向抑制 + 运行时审计报告）；远端有链接仍可访问，但绝不主动推送旧帖。
- **幂等可续传**：独立账本表 `(account, source, source_id, segment_no)` 唯一约束 + PG advisory lock；进程崩溃后重跑只补缺、不重复；内容哈希变化报冲突而非重发。
- **可验证**：`verify` 按账本逐行核对时间/ID 时间位/媒体顺序/回复链/无伪造互动/队列零任务。
- **可回滚**：`rollback` 按批次先预演；子帖先删、只删账本登记对象、检测到他人新互动默认阻止。
- **不伪造互动**：转发归档为文字引用、提及保留为文字、点赞/评论计数保留为元数据摘要行，不创建 Mastodon 原生 boost/点赞/通知。

## 环境要求

| 侧 | 要求 |
|---|---|
| 开发机（解析/下载/预演） | Ruby ≥ 3.2（仅标准库 + minitest）；媒体下载需可访问来源 CDN |
| 实例侧（导入/验证/回滚） | Mastodon 4.6.x（源码逻辑按部署版本实测校准）；`rails runner` 或 `docker compose exec` 执行入口 |

## 快速开始

### 1）开发机：解析与预演（不需要实例）

```powershell
git clone <本仓库>
cd sky-mastodon-tool
rake test          # 139 个单元测试

# 字段普查（不预设任何导出工具的字段名）
ruby tools/weibo-import/install/script/weibo_normalize.rb inspect --input <你的导出.json> --sample 20

# 人工确认字段映射后（模板见 tools/weibo-import/config/field_map.example.yml）
ruby tools/weibo-import/install/script/weibo_normalize.rb normalize --input <你的导出.json> `
  --map tools/weibo-import/config/field_map.yml --out tmp/normalized.jsonl --raw-dir tmp/raw_copy/

# 媒体下载（SSRF 防护：拒绝私网/环回/云元数据，逐跳校验重定向，魔数验 MIME）
ruby tools/weibo-import/install/script/weibo_normalize.rb fetch-media --input tmp/normalized.jsonl `
  --media-dir tmp/media --header 'User-Agent: <UA>' --header 'Referer: <来源站>'

# 预演报告（只读，不碰数据库）
ruby tools/weibo-import/install/script/weibo_import.rb plan --account <账号> --input tmp/normalized.jsonl
```

呈现策略参数（normalize 阶段固化，`plan`/`import` 如实回显）：

| 参数 | 取值 | 默认 |
|---|---|---|
| `--interactions` | `summary`（正文尾部计数行+评论入元数据）/ `metadata` / `counts` | `summary` |
| `--retweet-media` | `include`（转发原图按序挂载）/ `skip` | `include` |
| `--card` | `ignore` / `append` | `ignore` |

### 2）实例侧：导入（rails runner）

```bash
# 脚本树复制进实例（或 docker compose cp 进容器），随后：
RAILS_ENV=production bundle exec rails runner script/weibo_import.rb -- setup-ledger --execute

# 试导入 20 条（--limit 语义 = 20 条来源微博，不是拆分后帖子数）
RAILS_ENV=production bundle exec rails runner script/weibo_import.rb -- import \
  --account <账号> --input /path/normalized.jsonl --media-dir /path/media \
  --batch pilot-001 --limit 20 --execute --yes

RAILS_ENV=production bundle exec rails runner script/weibo_import.rb -- verify --account <账号> --batch pilot-001
RAILS_ENV=production bundle exec rails runner script/weibo_import.rb -- rollback --account <账号> --batch pilot-001   # 默认 dry-run
```

docker compose 部署的实例把入口换成 `docker compose exec -T <web服务> bundle exec rails runner ...`（注意 runner 与脚本参数间的 `--` 分隔符）。

> ⚠️ **安全红线**：`import` 是生产写操作。完整流程（环境检查 → 备份 → 映射确认 → 预演对账 → 试导入验收 → 全量）与每一步确认门见 [tools/weibo-import/docs/weibo-import.md](tools/weibo-import/docs/weibo-import.md)。

## 命令一览

| 子命令 | 环境 | 说明 |
|---|---|---|
| `plan` | 开发机/实例 | 预演报告（拆分数、媒体、异常清单），只读 |
| `env-check` | 实例 | 版本/部署形态/DB/Redis/存储/账号基线只读检查 + Snowflake 源码审计 |
| `setup-ledger` | 实例 | 幂等创建账本辅助表（不碰 Mastodon 核心表） |
| `import` | 实例 | 静默导入；支持 `--limit/--batch/--resume`；默认 dry-run，`--execute` 才写入 |
| `verify` | 实例 | 按账本逐行核对，PASS/FAIL 退出码 |
| `rollback` | 实例 | 按批次回滚；默认 dry-run；子帖先删；新互动默认阻止 |

## 目录结构

```text
tools/weibo-import/
├── install/script/          # 交付树（原样复制进实例）：CLI + 模块
│   ├── weibo_import.rb      # plan/import/verify/rollback/env-check/setup-ledger
│   ├── weibo_normalize.rb   # inspect/normalize/fetch-media（纯 Ruby）
│   └── weibo_import/        # adapter/normalize/splitter/downloader/id_allocator/
│                            # ledger/silence/importer/verify/rollback/backup...
├── config/                  # 字段映射模板（真实映射 gitignored，仓库零数据）
├── docs/                    # 操作手册 / 静默回调审计清单 / 映射报告模板
├── tests/                   # minitest 单元测试 + 合成 fixtures
└── testenv/                 # 一次性隔离 Mastodon 测试实例编排（setup/teardown）
deploy/                      # 安装脚本（install.ps1/install.sh）与 compose 用法模板
```

## 开发

```powershell
rake lint    # 逐文件 ruby -c 语法检查
rake test    # 全部单元测试（纯逻辑，无网络/无数据库/无 Rails）
rake install # deploy/install.ps1 dry-run 预览
```

- **仓库零数据红线**：真实导出、媒体、备份、密钥、真实字段映射一律 gitignore；测试 fixtures 全部为合成数据。
- **实例行为适配**：一切以部署实例的实际源码为准（`env-check` 会输出 Snowflake/验证器审计定位），不预设版本行为。
- 集成验证建议使用 `tools/weibo-import/testenv/` 的一次性 Mastodon 容器（独立 compose project，仅绑 127.0.0.1，用后 `teardown.ps1` 全量销毁）。

## 贡献

欢迎 issue / PR：

1. Fork 并切分支；改动需保持 `rake lint && rake test` 全绿。
2. 涉及实例写入行为的改动，请在 `testenv` 完成隔离验证并在 PR 中附验证输出。
3. 不要提交任何真实账号数据、导出样本、密钥或实例域名——CI/评审会拒绝。
4. 新增来源平台适配时遵循现有声明式映射风格（`field_map.example.yml`），先 `inspect` 普查再写映射。

## 许可

尚未声明。公开引用/二次开发前请先通过 issue 联系作者确认授权。

---

## English intro

**sky-mastodon-tool** is a single-operator toolbox for self-hosted Mastodon instances. Its first tool, **weibo-import**, archives Weibo JSON exports into a local Mastodon account with **original timestamps, historical Snowflake IDs, silent creation (no fan-out/notifications/webhooks), idempotency via a ledger table, per-batch verification and rollback** — without ever touching existing posts or fabricating interactions. See the Chinese docs above for the full pipeline and safety gates.
