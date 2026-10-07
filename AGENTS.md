# AGENTS.md — sky-mastodon-tool

一句话定位：面向自托管 Mastodon 实例（标称 4.6.2，一切以 `env_check` 实测为准）的**单人运维工具仓**——无 Web 界面、无自有服务、无自有数据库，一切生产读写都发生在目标 Mastodon 实例上（`rails runner` 或 `docker compose exec`）。

共享规则：遵循 [`../sky-guiding/AGENTS.md`](../sky-guiding/AGENTS.md) 总入口及其引用的 `.docs/`、Skill 与 Agent。本文件只声明本仓库的例外与事实，不重复共享规则。

## 仓库级例外（相对 sky-guiding 共享基线）

1. **不适用全栈 Next.js/go-zero 标准**：无 `web/`/`server/` 目录、无前后端分层脚手架、无数据库迁移体系。
2. **不接入 sky-sso**：无登录界面；身份 = 目标本地 Mastodon 账号 + 服务器服务用户 + 每步确认门。
3. **语言基线例外**：本仓库主体是 Ruby（运行侧 stdlib-only 脚本 + minitest），Node >= 24 / pnpm 基线不适用。
4. **不自带 PostgreSQL/Redis/存储**：复用目标实例的 DB/Redis/媒体存储，仓库内不出现常驻 compose 服务。唯一例外：`tools/weibo-import/testenv/` 的**一次性**本地测试编排（批次 B 集成测试用），必须用后即 `teardown.ps1`（`down -v`）销毁。
5. **仓库零数据**：数据/媒体/备份/密钥/真实字段映射（`config/field_map.yml`）一律 gitignore；测试 fixture 全部为自制合成数据，绝不包含真实微博内容。

## 命令

- `rake test` — 运行 `tools/weibo-import/tests/unit` 全部 minitest（纯逻辑，无需实例）。
- `rake lint` — 对 `install/` 树与 `tests/` 逐文件 `ruby -c` 语法检查。
- `rake install` — 调用 `deploy/install.ps1`（默认 dry-run 预览；真复制需 `-Execute`）。
- `tools/weibo-import/testenv/setup.ps1` — 一键初始化隔离 Mastodon 4.6.2 测试容器（仅绑 127.0.0.1，见该目录 README）。
- `tools/weibo-import/testenv/teardown.ps1` — 销毁测试容器与全部数据卷（共享 Docker 环境必须用后即清）。

## 执行环境

- 开发机：Windows（`F:\Projects\sky-galaxy\`），负责写代码、跑单测、跑纯 Ruby CLI（inspect/map/normalize/plan）。
- 运行侧：Linux 上的 Mastodon 实例。`deploy/install.ps1`（或 `install.sh`）把 `tools/weibo-import/install/` 树复制到 `$MASTODON_DIR`，再以 `rails runner` / `docker compose exec` 执行（模板见 `deploy/compose-usage.md`，服务名/路径必须按实例实际值替换）。
- 运行侧脚本只依赖 Ruby 标准库（optparse/net/http/digest/json/securerandom/yaml 等），**绝不向实例引入新 gem**。

## 红线（批次边界）

- **未经 `docs/weibo-import.md` 定义的确认门，不得对生产实例做任何写入。**
- 批次 A：`import` / `verify` / `rollback` / `setup-ledger` 是占位（批次 B 交付）；`plan` / `env-check`（Rails 部分）与 `weibo_normalize.rb` 的 `inspect`/`map`/`normalize`/`fetch-media` 真实可用。
- 时间保真：绝不修改来源时间；无法解析/异常时间进错误清单，绝不用当前时间顶替。
- 可见性只能收紧不能放宽；导入默认 `unlisted`。
- 绝不为了排序人为增减 `created_at`（Snowflake ID 分配同样不得改动 `created_at`）。
